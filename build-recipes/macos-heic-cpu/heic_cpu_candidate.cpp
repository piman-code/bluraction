// QA candidate only. Receives final, upright, unassociated RGBA8 sRGB pixels;
// it never opens an original document, receives its metadata, or publishes to a
// user destination. The supervising process owns deadlines/cancellation.
#include <libheif/heif.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint64_t MAX_PIXELS = 24000000;
constexpr uint64_t MAX_OUTPUT = 256ULL * 1024 * 1024;
struct FD {
  int value = -1;
  explicit FD(int fd) : value(fd) { if (fd < 0) throw std::runtime_error("owned file open failed"); }
  ~FD() { if (value >= 0) ::close(value); }
  FD(const FD&) = delete; FD& operator=(const FD&) = delete;
};
void check(heif_error e) {
  if (e.code != heif_error_Ok) throw std::runtime_error(e.message ? e.message : "libheif failed");
}
void require(bool ok, const char* reason) { if (!ok) throw std::runtime_error(reason); }
int integer(const char* text, int maximum, int minimum = 1) {
  char* end = nullptr; errno = 0; long value = std::strtol(text, &end, 10);
  require(!errno && end != text && *end == 0 && value >= minimum && value <= maximum, "invalid bounded integer");
  return static_cast<int>(value);
}
void write_all(int fd, const void* data, size_t count) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  while (count) {
    ssize_t n = ::write(fd, bytes, count);
    if (n < 0 && errno == EINTR) continue;
    require(n > 0, "owned output write failed"); bytes += n; count -= static_cast<size_t>(n);
  }
}
struct Writer { int fd; uint64_t bytes = 0; bool failed = false; };
heif_error writer(heif_context*, const void* data, size_t count, void* opaque) noexcept {
  auto* w = static_cast<Writer*>(opaque);
  try {
    require(count <= MAX_OUTPUT - w->bytes, "encoded output budget exceeded");
    write_all(w->fd, data, count); w->bytes += count;
    return {heif_error_Ok, heif_suberror_Unspecified, "ok"};
  } catch (...) {
    w->failed = true;
    return {heif_error_Encoding_error, heif_suberror_Unspecified, "bounded owned write failed"};
  }
}
using Context = std::unique_ptr<heif_context, decltype(&heif_context_free)>;
using Image = std::unique_ptr<heif_image, decltype(&heif_image_release)>;
using Handle = std::unique_ptr<heif_image_handle, decltype(&heif_image_handle_release)>;
using Encoder = std::unique_ptr<heif_encoder, decltype(&heif_encoder_release)>;
using NCLX = std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>;
using Options = std::unique_ptr<heif_encoding_options, decltype(&heif_encoding_options_free)>;
int fresh(int directory, const char* name) {
  return ::openat(directory, name, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0600);
}
}

int main(int argc, char** argv) {
  // Fixed arguments: width height quality owned-directory. Quality is 0..100;
  // this candidate does NOT equate quality100 with RGB lossless or 4:4:4.
  if (argc != 5) { std::cerr << "usage: heic_cpu_candidate width height quality owned-directory < final.rgba\n"; return 2; }
  int directory_fd = -1;
  bool ready = false;
  try {
    int width = integer(argv[1], 24000000), height = integer(argv[2], 24000000), quality = integer(argv[3], 100, 0);
    uint64_t pixels = uint64_t(width) * uint64_t(height);
    require(pixels <= MAX_PIXELS, "24MP input budget exceeded");
    FD directory(::open(argv[4], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    directory_fd = directory.value;
    struct stat ds{}; require(::fstat(directory.value, &ds) == 0 && ds.st_uid == ::getuid() &&
      (ds.st_mode & 0777) == 0700, "caller-owned private 0700 directory required");
    // The opened dirfd anchors all writes even if a parent path is retargeted.
    FD output(fresh(directory.value, "candidate.heic"));
    std::vector<uint8_t> rgba(static_cast<size_t>(pixels * 4));
    size_t offset = 0;
    while (offset < rgba.size()) {
      ssize_t n = ::read(STDIN_FILENO, rgba.data() + offset, rgba.size() - offset);
      if (n < 0 && errno == EINTR) continue;
      require(n > 0, "truncated RGBA8 input"); offset += static_cast<size_t>(n);
    }
    uint8_t extra; ssize_t tail;
    do { tail = ::read(STDIN_FILENO, &extra, 1); } while (tail < 0 && errno == EINTR);
    require(tail == 0, "extra RGBA bytes or input read failure");
    bool alpha = false;
    for (size_t p = 0; p < rgba.size(); p += 4) {
      alpha |= rgba[p + 3] != 255;
      // No hidden source RGB in completely transparent encoded pixels.
      if (rgba[p + 3] == 0) rgba[p] = rgba[p + 1] = rgba[p + 2] = 0;
    }
    require(std::string(heif_get_version()) == "1.23.5", "exact libheif runtime version required");
    check(heif_init(nullptr));
    struct Library { ~Library() { heif_deinit(); } } library;
    Context context(heif_context_alloc(), heif_context_free); require(bool(context), "context allocation failed");
    const heif_encoder_descriptor* descriptor = nullptr;
    require(heif_get_encoder_descriptors(heif_compression_HEVC, "kvazaar", nullptr, 0) == 1 &&
      heif_get_encoder_descriptors(heif_compression_HEVC, "kvazaar", &descriptor, 1) == 1 && descriptor &&
      std::strcmp(heif_encoder_descriptor_get_id_name(descriptor), "kvazaar") == 0,
      "one explicit kvazaar CPU encoder required");
    // libheif1.23.5 always registers its internal uncompressed mask codec.
    // Permit that exact built-in plus Kvazaar; reject every other codec/plugin.
    const heif_encoder_descriptor* installed[3] = {};
    require(heif_get_encoder_descriptors(heif_compression_undefined, nullptr, nullptr, 0) == 2 &&
      heif_get_encoder_descriptors(heif_compression_undefined, nullptr, installed, 3) == 2,
      "unexpected encoder count in owned build");
    bool saw_kvazaar = false, saw_mask = false;
    for (int i = 0; i < 2; ++i) {
      const char* id = heif_encoder_descriptor_get_id_name(installed[i]);
      auto format = heif_encoder_descriptor_get_compression_format(installed[i]);
      if (id && std::strcmp(id, "kvazaar") == 0 && format == heif_compression_HEVC && !saw_kvazaar)
        saw_kvazaar = true;
      else if (id && std::strcmp(id, "mask") == 0 && format == heif_compression_mask && !saw_mask)
        saw_mask = true;
      else throw std::runtime_error("unexpected codec in owned build");
    }
    require(saw_kvazaar && saw_mask, "required owned codec census incomplete");
    heif_encoder* ep = nullptr; check(heif_context_get_encoder(context.get(), descriptor, &ep));
    Encoder encoder(ep, heif_encoder_release); check(heif_encoder_set_lossy_quality(ep, quality));
    heif_image* ip = nullptr;
    check(heif_image_create(width, height, heif_colorspace_RGB, alpha ? heif_chroma_interleaved_RGBA : heif_chroma_interleaved_RGB, &ip));
    Image image(ip, heif_image_release);
    check(heif_image_add_plane(ip, heif_channel_interleaved, width, height, 8));
    heif_image_set_premultiplied_alpha(ip, 0);
    size_t stride = 0; auto* plane = heif_image_get_plane2(ip, heif_channel_interleaved, &stride);
    int channels = alpha ? 4 : 3;
    require(plane && stride >= size_t(width) * channels, "invalid input plane stride");
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        std::memcpy(plane + size_t(y) * stride + size_t(x) * channels,
          rgba.data() + (size_t(y) * width + x) * 4, channels);
      }
    }
    // Fresh sRGB/BT.709 primaries, sRGB transfer, BT.601 YCbCr matrix, full range.
    // Source ICC/EXIF/GPS/thumbnail/depth/gain-map data is never accepted.
    NCLX nclx(heif_nclx_color_profile_alloc(), heif_nclx_color_profile_free);
    require(bool(nclx), "NCLX allocation failed");
    check(heif_nclx_color_profile_set_color_primaries(nclx.get(), 1));
    check(heif_nclx_color_profile_set_transfer_characteristics(nclx.get(), 13));
    check(heif_nclx_color_profile_set_matrix_coefficients(nclx.get(), 6)); nclx->full_range_flag = 1;
    check(heif_image_set_nclx_color_profile(ip, nclx.get()));
    Options options(heif_encoding_options_alloc(), heif_encoding_options_free);
    require(bool(options), "options allocation failed");
    options->save_alpha_channel = alpha; options->image_orientation = heif_orientation_normal;
    options->output_nclx_profile = nclx.get();
    options->macOS_compatibility_workaround_no_nclx_profile = 0;
    options->color_conversion_options.preferred_chroma_downsampling_algorithm = heif_chroma_downsampling_average;
    options->color_conversion_options.only_use_preferred_chroma_algorithm = 1;
    heif_image_handle* encodedp = nullptr;
    check(heif_context_encode_image(context.get(), ip, ep, options.get(), &encodedp));
    Handle encoded(encodedp, heif_image_handle_release);
    Writer w{output.value}; heif_writer hw{1, writer}; check(heif_context_write(context.get(), &hw, &w));
    require(!w.failed && w.bytes > 0 && ::fsync(output.value) == 0, "candidate not durable");
    std::vector<uint8_t> bytes(static_cast<size_t>(w.bytes)); size_t read_offset = 0;
    while (read_offset < bytes.size()) {
      ssize_t n = ::pread(output.value, bytes.data() + read_offset, bytes.size() - read_offset, read_offset);
      if (n < 0 && errno == EINTR) continue;
      require(n > 0, "candidate readback failed"); read_offset += static_cast<size_t>(n);
    }
    Context reopened(heif_context_alloc(), heif_context_free); require(bool(reopened), "readback allocation failed");
    check(heif_context_read_from_memory_without_copy(reopened.get(), bytes.data(), bytes.size(), nullptr));
    require(heif_context_get_number_of_top_level_images(reopened.get()) == 1, "unexpected unmasked top-level image");
    heif_image_handle* hp = nullptr; check(heif_context_get_primary_image_handle(reopened.get(), &hp));
    Handle handle(hp, heif_image_handle_release);
    require(heif_image_handle_get_width(hp) == width && heif_image_handle_get_height(hp) == height,
      "readback displayed dimensions differ");
    require(bool(heif_image_handle_has_alpha_channel(hp)) == alpha, "alpha missing or unexpectedly added");
    require(heif_image_handle_get_number_of_thumbnails(hp) == 0 &&
      heif_image_handle_get_number_of_metadata_blocks(hp, nullptr) == 0 &&
      heif_image_handle_get_number_of_depth_images(hp) == 0 &&
      heif_image_handle_get_raw_color_profile_size(hp) == 0,
      "unexpected source metadata/thumbnail/depth/ICC");
    // Filter alpha only; all other auxiliary items must be absent.
    require(heif_image_handle_get_number_of_auxiliary_images(hp, LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA) == 0,
      "unexpected non-alpha auxiliary item");
    heif_color_profile_nclx* np = nullptr; check(heif_image_handle_get_nclx_color_profile(hp, &np));
    NCLX read_nclx(np, heif_nclx_color_profile_free);
    require(np->color_primaries == 1 && np->transfer_characteristics == 13 && np->matrix_coefficients == 6 &&
      np->full_range_flag == 1, "readback NCLX differs");
    heif_image* dp = nullptr; check(heif_decode_image(hp, &dp, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, nullptr));
    Image decoded(dp, heif_image_release); size_t decoded_stride = 0;
    const auto* decoded_plane = heif_image_get_plane_readonly2(dp, heif_channel_interleaved, &decoded_stride);
    require(decoded_plane && decoded_stride >= size_t(width) * 4 && heif_image_get_width(dp, heif_channel_interleaved) == width &&
      heif_image_get_height(dp, heif_channel_interleaved) == height && !heif_image_is_premultiplied_alpha(dp),
      "invalid decoded RGBA contract");
    FD decoded_file(fresh(directory.value, "decoded.rgba"));
    uint64_t rgb_sum = 0, rgb_count = 0, alpha_mismatch = 0; int rgb_max = 0;
    for (int y = 0; y < height; ++y) {
      const uint8_t* row = decoded_plane + size_t(y) * decoded_stride;
      write_all(decoded_file.value, row, size_t(width) * 4);
      for (int x = 0; x < width; ++x) {
        size_t at = (size_t(y) * width + x) * 4;
        alpha_mismatch += row[x * 4 + 3] != rgba[at + 3];
        if (rgba[at + 3]) for (int c = 0; c < 3; ++c) {
          int difference = std::abs(int(row[x * 4 + c]) - int(rgba[at + c]));
          rgb_sum += difference; ++rgb_count; if (difference > rgb_max) rgb_max = difference;
        }
      }
    }
    require(::fsync(decoded_file.value) == 0 && alpha_mismatch == 0, "alpha bytes not exactly preserved");
    FD report(fresh(directory.value, "report.json"));
    std::string json = "{\"status\":\"candidate-readback-complete\",\"encoder\":\"kvazaar\",\"libheif\":\"1.23.5\",\"width\":" +
      std::to_string(width) + ",\"height\":" + std::to_string(height) + ",\"quality\":" + std::to_string(quality) +
      ",\"encodedColorChroma\":\"420\",\"input\":\"upright-unassociated-RGBA8-sRGB\",\"alphaPresent\":" + (alpha ? "true" : "false") +
      ",\"alphaMismatch\":0,\"nclx\":[1,13,6,1],\"sourceMetadataCopied\":false,\"rgbMeanAbsoluteDifference\":" +
      std::to_string(rgb_count ? double(rgb_sum) / double(rgb_count) : 0) + ",\"rgbMaximumAbsoluteDifference\":" + std::to_string(rgb_max) +
      ",\"colorParityApproved\":false,\"publishedToUserDestination\":false,\"HDRVerified\":false,\"releaseApproved\":false}\n";
    write_all(report.value, json.data(), json.size()); require(::fsync(report.value) == 0 && ::fsync(directory.value) == 0, "report durability failed");
    ready = true; std::cout << json; return 0;
  } catch (const std::exception& e) {
    std::cerr << "CPU candidate failed: " << e.what() << '\n';
    // Partial owned artifacts remain diagnostic evidence and must NEVER be
    // treated as usable without exit0 + the final complete report. No user output.
    (void)directory_fd; (void)ready; return 3;
  }
}
