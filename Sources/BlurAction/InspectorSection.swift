import AppKit

/// Keeps controls in the view hierarchy while allowing less frequent settings to fold away.
final class InspectorSection: NSStackView {
    let toggle = NSButton()
    let content = NSStackView()
    private let sectionTitle: String
    var isExpanded: Bool {
        get { !content.isHidden }
        set {
            content.isHidden = !newValue
            toggle.title = "\(newValue ? "▾" : "▸") \(sectionTitle)"
            toggle.setAccessibilityValue(newValue ? "펼침" : "접힘")
        }
    }

    init(title: String, identifier: String, views: [NSView]) {
        sectionTitle = title
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        toggle.identifier = NSUserInterfaceItemIdentifier(identifier + "Toggle")
        toggle.bezelStyle = .inline
        toggle.font = .systemFont(ofSize: 13, weight: .medium)
        toggle.setAccessibilityLabel(title)
        toggle.target = self
        toggle.action = #selector(toggleExpanded)
        content.identifier = NSUserInterfaceItemIdentifier(identifier + "Content")
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        for view in views { content.addArrangedSubview(view) }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        toggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        addArrangedSubview(toggle)
        addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        isExpanded = false
    }

    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggleExpanded() { isExpanded.toggle() }
}
