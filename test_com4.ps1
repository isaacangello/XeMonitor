Add-Type -AssemblyName System.IO.Ports
try {
    $port = New-Object System.IO.Ports.SerialPort("COM4", 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $port.Open()
    Write-Host "OK - COM4 aberta em 115200" -ForegroundColor Green
    $port.Close()
} catch {
    Write-Host "Falha em 115200: $_" -ForegroundColor Red
}
try {
    $port2 = New-Object System.IO.Ports.SerialPort("COM4", 9600, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $port2.Open()
    Write-Host "OK - COM4 aberta em 9600" -ForegroundColor Green
    $port2.Close()
} catch {
    Write-Host "Falha em 9600: $_" -ForegroundColor Red
}
