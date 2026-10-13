# Preserved prototype only; not bundled or executed by the local candidate.
# Native Windows OCR bridge. Image bytes arrive through stdin, never a temp file.
# Does not change execution policies or write/transmit media or recognized text.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Globalization.Language, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType=WindowsRuntime]
    $null = [Windows.Storage.Streams.DataWriter, Windows.Foundation, ContentType=WindowsRuntime]
    $ocrAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Length -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    function Await-Ocr($Operation, [Type]$ResultType) {
        $ocrTask = $ocrAsTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
        return $ocrTask.GetAwaiter().GetResult()
    }
    $ocrPayload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $ocrBytes = [Convert]::FromBase64String($ocrPayload.png)
    $ocrStream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $ocrWriter = New-Object Windows.Storage.Streams.DataWriter($ocrStream)
    $ocrWriter.WriteBytes($ocrBytes)
    $null = Await-Ocr ($ocrWriter.StoreAsync()) ([UInt32])
    $ocrStream.Seek(0)
    $ocrDecoder = Await-Ocr ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ocrStream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $ocrBitmap = Await-Ocr ($ocrDecoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $ocrEngines = @()
    foreach ($ocrLanguage in @('ko-KR','en-US')) {
        $ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language($ocrLanguage)))
        if ($null -ne $ocrEngine) { $ocrEngines += $ocrEngine }
    }
    if ($ocrEngines.Count -eq 0) {
        $ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -ne $ocrEngine) { $ocrEngines += $ocrEngine }
    }
    $ocrBoxes = @()
    foreach ($ocrEngine in $ocrEngines) {
        $ocrResult = Await-Ocr ($ocrEngine.RecognizeAsync($ocrBitmap)) ([Windows.Media.Ocr.OcrResult])
        foreach ($ocrLine in $ocrResult.Lines) {
            $ocrLeft = [double]::PositiveInfinity; $ocrTop = [double]::PositiveInfinity
            $ocrRight = 0.; $ocrBottom = 0.
            foreach ($ocrWord in $ocrLine.Words) {
                $ocrRect = $ocrWord.BoundingRect
                $ocrLeft = [Math]::Min($ocrLeft,$ocrRect.X); $ocrTop = [Math]::Min($ocrTop,$ocrRect.Y)
                $ocrRight = [Math]::Max($ocrRight,$ocrRect.X+$ocrRect.Width)
                $ocrBottom = [Math]::Max($ocrBottom,$ocrRect.Y+$ocrRect.Height)
            }
            if (![double]::IsInfinity($ocrLeft)) { $ocrBoxes += ,@($ocrLeft,$ocrTop,$ocrRight,$ocrBottom) }
        }
    }
    [Console]::WriteLine((@{available=($ocrEngines.Count -gt 0);boxes=@($ocrBoxes)} | ConvertTo-Json -Depth 5 -Compress))
    $ocrBitmap.Dispose(); $ocrWriter.DetachStream() | Out-Null; $ocrWriter.Dispose(); $ocrStream.Dispose()
} catch {
    [Console]::WriteLine('{"available":false,"boxes":[],"reason":"native-ocr-unavailable"}')
}
