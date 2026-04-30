# Copyright (C) 2026 Andrea Tondelli
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

Set-StrictMode -Version Latest

# ── Register banks (index = address, 0..65535) ───────────────────────────────
$script:HoldingRegisters  = [uint16[]]::new(65536)
$script:InputRegisters    = [uint16[]]::new(65536)
$script:Coils             = [bool[]]::new(65536)
$script:DiscreteInputs    = [bool[]]::new(65536)

# ── Error injection ───────────────────────────────────────────────────────────
# Key   : "<FC>:<Address>"  e.g. "3:100"   — errore su FC + indirizzo specifico
#         "<FC>:*"          e.g. "3:*"     — errore su tutti gli indirizzi del FC
# Value : codice eccezione Modbus (byte)
#   0x01 = Illegal Function
#   0x02 = Illegal Data Address
#   0x03 = Illegal Data Value
#   0x04 = Slave Device Failure
$script:ErrorMap         = @{}
$script:GlobalDisconnect = $false  # se $true chiude la connessione su qualsiasi richiesta
$script:GlobalDelayMs    = 0       # ms di attesa prima di rispondere (0 = nessun delay)
$script:IdleTimeoutSec   = 0       # se > 0 chiude la connessione dopo N secondi senza richieste Modbus

# ── Public API ────────────────────────────────────────────────────────────────

function Set-HoldingRegister {
    param([uint16]$Address, [uint16]$Value)
    $script:HoldingRegisters[$Address] = $Value
}

function Get-HoldingRegister {
    param([uint16]$Address)
    $script:HoldingRegisters[$Address]
}

function Set-InputRegister {
    param([uint16]$Address, [uint16]$Value)
    $script:InputRegisters[$Address] = $Value
}

function Get-InputRegister {
    param([uint16]$Address)
    $script:InputRegisters[$Address]
}

function Set-Coil {
    param([uint16]$Address, [bool]$Value)
    $script:Coils[$Address] = $Value
}

function Get-Coil {
    param([uint16]$Address)
    $script:Coils[$Address]
}

function Set-DiscreteInput {
    param([uint16]$Address, [bool]$Value)
    $script:DiscreteInputs[$Address] = $Value
}

function Get-DiscreteInput {
    param([uint16]$Address)
    $script:DiscreteInputs[$Address]
}

# Inietta un'eccezione Modbus per FC + indirizzo specifico.
# Esempio: Set-ModbusError -FunctionCode 3 -Address 100 -ExceptionCode 0x02
function Set-ModbusError {
    param(
        [byte]$FunctionCode,
        [uint16]$Address,
        [byte]$ExceptionCode = 0x02
    )
    $script:ErrorMap["${FunctionCode}:${Address}"] = $ExceptionCode
}

# Inietta un'eccezione Modbus per qualsiasi richiesta a un dato FC.
# Esempio: Set-ModbusFunctionError -FunctionCode 3 -ExceptionCode 0x01
function Set-ModbusFunctionError {
    param(
        [byte]$FunctionCode,
        [byte]$ExceptionCode = 0x01
    )
    $script:ErrorMap["${FunctionCode}:*"] = $ExceptionCode
}

function Clear-ModbusError {
    param([byte]$FunctionCode, [uint16]$Address)
    $script:ErrorMap.Remove("${FunctionCode}:${Address}")
}

function Clear-AllModbusErrors {
    $script:ErrorMap.Clear()
}

# Chiude la connessione TCP senza rispondere su qualsiasi richiesta.
function Enable-ModbusDisconnect  { $script:GlobalDisconnect = $true  }
function Disable-ModbusDisconnect { $script:GlobalDisconnect = $false }

# Ritarda la risposta di N ms su qualsiasi richiesta.
# Se N supera il timeout del client, il client va in timeout.
function Set-ModbusDelay   { param([int]$DelayMs) $script:GlobalDelayMs = $DelayMs }
function Clear-ModbusDelay { $script:GlobalDelayMs = 0 }

# Chiude la connessione se non arrivano richieste Modbus entro N secondi dall'ultima.
# Simula "Enable Server Socket Idle Connection Timeout" dei dispositivi reali.
# I TCP keepalive del client non resettano questo timer (solo le richieste Modbus lo resettano).
function Set-ModbusIdleTimeout   { param([int]$Seconds) $script:IdleTimeoutSec = $Seconds }
function Clear-ModbusIdleTimeout { $script:IdleTimeoutSec = 0 }

# ── Log helpers (interni) ────────────────────────────────────────────────────

function Format-RegVal {
    param([uint16]$v)
    $hex = '0x' + $v.ToString('X4')
    $bin = '0b' + [Convert]::ToString($v, 2).PadLeft(16, '0')
    return "$v  ($hex | $bin)"
}

function Format-BitVal {
    param([bool]$v)
    if ($v) { return 'ON  (1)' } else { return 'OFF (0)' }
}

function Write-Log {
    param([string]$Message)
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
}

# ── Frame helpers (interni) ───────────────────────────────────────────────────

function Build-MbapResponse {
    param([byte[]]$Request, [byte[]]$Pdu)
    [uint16]$len = 1 + $Pdu.Length   # unit id (1) + PDU
    [byte[]]$hdr = $Request[0],                      # transaction id hi
                   $Request[1],                      # transaction id lo
                   0x00, 0x00,                       # protocol id
                   [byte]($len -shr 8),              # length hi
                   [byte]($len -band 0xFF),          # length lo
                   $Request[6]                       # unit id
    return $hdr + $Pdu
}

function Build-ExceptionResponse {
    param([byte[]]$Request, [byte]$Fc, [byte]$ExCode)
    [byte[]]$pdu = ($Fc -bor 0x80), $ExCode
    return Build-MbapResponse $Request $pdu
}

function Get-InjectedError {
    param([byte]$Fc, [uint16]$Address)
    $keySpecific = "${Fc}:${Address}"
    $keyWildcard = "${Fc}:*"
    if ($script:ErrorMap.ContainsKey($keySpecific)) { return [byte]$script:ErrorMap[$keySpecific] }
    if ($script:ErrorMap.ContainsKey($keyWildcard))  { return [byte]$script:ErrorMap[$keyWildcard] }
    return $null
}

# ── FC handlers (interni) ─────────────────────────────────────────────────────

function Invoke-ReadBits {
    param([byte[]]$Request, [uint16]$StartAddr, [bool[]]$Bank)
    [byte]$fc = $Request[7]
    if ($Request.Length -lt 12) { return Build-ExceptionResponse $Request $fc 0x03 }

    [uint16]$count = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    if ($count -lt 1 -or $count -gt 2000) { return Build-ExceptionResponse $Request $fc 0x03 }

    [byte]$byteCount = [byte][Math]::Ceiling($count / 8.0)
    [byte[]]$coilBytes = [byte[]]::new($byteCount)
    for ($i = 0; $i -lt $count; $i++) {
        if ($Bank[$StartAddr + $i]) {
            $coilBytes[[int]($i / 8)] = $coilBytes[[int]($i / 8)] -bor [byte](1 -shl ($i % 8))
        }
    }

    [byte[]]$pdu = $fc, $byteCount
    $pdu += $coilBytes

    $bankName = if ($fc -eq 0x01) { 'Coil' } else { 'DI' }
    Write-Log "  [READ]  $bankName[$StartAddr..$($StartAddr + $count - 1)]"
    for ($i = 0; $i -lt $count; $i++) {
        Write-Host "          [$($StartAddr + $i)] = $(Format-BitVal $Bank[$StartAddr + $i])"
    }

    return Build-MbapResponse $Request $pdu
}

function Invoke-ReadRegisters {
    param([byte[]]$Request, [uint16]$StartAddr, [uint16[]]$Bank)
    [byte]$fc = $Request[7]
    if ($Request.Length -lt 12) { return Build-ExceptionResponse $Request $fc 0x03 }

    [uint16]$count = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    if ($count -lt 1 -or $count -gt 125) { return Build-ExceptionResponse $Request $fc 0x03 }

    [byte[]]$pdu = $fc, [byte]($count * 2)
    $bankName = if ($fc -eq 0x03) { 'HR' } else { 'IR' }
    Write-Log "  [READ]  $bankName[$StartAddr..$($StartAddr + $count - 1)]"
    for ($i = 0; $i -lt $count; $i++) {
        [uint16]$val = $Bank[$StartAddr + $i]
        $pdu += [byte]($val -shr 8)
        $pdu += [byte]($val -band 0xFF)
        Write-Host "          [$($StartAddr + $i)] = $(Format-RegVal $val)"
    }
    return Build-MbapResponse $Request $pdu
}

function Invoke-WriteSingle {
    param([byte[]]$Request, [uint16]$StartAddr)
    if ($Request.Length -lt 12) { return Build-ExceptionResponse $Request 0x06 0x03 }
    [uint16]$value = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    $script:HoldingRegisters[$StartAddr] = $value
    Write-Log "  [WRITE] HR[$StartAddr] = $(Format-RegVal $value)"
    return $Request[0..11]   # echo del frame per FC06
}

function Invoke-WriteMultiple {
    param([byte[]]$Request, [uint16]$StartAddr)
    if ($Request.Length -lt 13) { return Build-ExceptionResponse $Request 0x10 0x03 }

    [uint16]$count   = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    [byte]$byteCount = $Request[12]
    if ($Request.Length -lt 13 + $byteCount) { return Build-ExceptionResponse $Request 0x10 0x03 }

    for ($i = 0; $i -lt $count; $i++) {
        [uint16]$val = ([uint16]$Request[13 + $i * 2] -shl 8) -bor $Request[14 + $i * 2]
        $script:HoldingRegisters[$StartAddr + $i] = $val
        Write-Log "  [WRITE] HR[$($StartAddr + $i)] = $(Format-RegVal $val)"
    }

    [byte[]]$pdu = 0x10,
                   [byte]($StartAddr -shr 8), [byte]($StartAddr -band 0xFF),
                   [byte]($count -shr 8),     [byte]($count -band 0xFF)
    return Build-MbapResponse $Request $pdu
}

function Invoke-WriteSingleCoil {
    param([byte[]]$Request, [uint16]$StartAddr)
    if ($Request.Length -lt 12) { return Build-ExceptionResponse $Request 0x05 0x03 }
    [uint16]$rawValue = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    if ($rawValue -ne 0xFF00 -and $rawValue -ne 0x0000) {
        return Build-ExceptionResponse $Request 0x05 0x03
    }
    [bool]$on = ($rawValue -eq 0xFF00)
    $script:Coils[$StartAddr] = $on
    Write-Log "  [WRITE] Coil[$StartAddr] = $(Format-BitVal $on)"
    return $Request[0..11]   # echo del frame per FC05
}

function Invoke-WriteMultipleCoils {
    param([byte[]]$Request, [uint16]$StartAddr)
    if ($Request.Length -lt 13) { return Build-ExceptionResponse $Request 0x0F 0x03 }

    [uint16]$count   = ([uint16]$Request[10] -shl 8) -bor $Request[11]
    [byte]$byteCount = $Request[12]
    if ($Request.Length -lt 13 + $byteCount) { return Build-ExceptionResponse $Request 0x0F 0x03 }

    for ($i = 0; $i -lt $count; $i++) {
        [byte]$b    = $Request[13 + [int]($i / 8)]
        [bool]$on   = [bool]($b -band (1 -shl ($i % 8)))
        $script:Coils[$StartAddr + $i] = $on
        Write-Log "  [WRITE] Coil[$($StartAddr + $i)] = $(Format-BitVal $on)"
    }

    [byte[]]$pdu = 0x0F,
                   [byte]($StartAddr -shr 8), [byte]($StartAddr -band 0xFF),
                   [byte]($count -shr 8),     [byte]($count -band 0xFF)
    return Build-MbapResponse $Request $pdu
}

# ── Request dispatcher ────────────────────────────────────────────────────────

function Invoke-HandleRequest {
    param([byte[]]$Request)

    if ($Request.Length -lt 8) { return $null }

    [byte]$fc = $Request[7]

    if ($Request.Length -lt 10) {
        return Build-ExceptionResponse $Request $fc 0x03
    }

    [uint16]$startAddr = ([uint16]$Request[8] -shl 8) -bor $Request[9]

    if ($script:GlobalDisconnect) {
        Write-Log "  [DISCONNECT] closing connection"
        return $null
    }

    if ($script:GlobalDelayMs -gt 0) {
        Write-Log "  [DELAY] $($script:GlobalDelayMs)ms before responding..."
        Start-Sleep -Milliseconds $script:GlobalDelayMs
    }

    $injected = Get-InjectedError $fc $startAddr
    if ($null -ne $injected) {
        Write-Log "  [INJECT] FC=0x$($fc.ToString('X2')) Addr=$startAddr -> Exception=0x$($injected.ToString('X2'))"
        return Build-ExceptionResponse $Request $fc $injected
    }

    switch ($fc) {
        0x01 { return Invoke-ReadBits         $Request $startAddr $script:Coils }
        0x02 { return Invoke-ReadBits         $Request $startAddr $script:DiscreteInputs }
        0x03 { return Invoke-ReadRegisters    $Request $startAddr $script:HoldingRegisters }
        0x04 { return Invoke-ReadRegisters    $Request $startAddr $script:InputRegisters }
        0x05 { return Invoke-WriteSingleCoil  $Request $startAddr }
        0x06 { return Invoke-WriteSingle      $Request $startAddr }
        0x0F { return Invoke-WriteMultipleCoils $Request $startAddr }
        0x10 { return Invoke-WriteMultiple    $Request $startAddr }
        default {
            Write-Log "  [WARN] unsupported FC: 0x$($fc.ToString('X2'))"
            return Build-ExceptionResponse $Request $fc 0x01
        }
    }
}

# ── Server ────────────────────────────────────────────────────────────────────

function Start-ModbusServer {
    <#
    .SYNOPSIS
        Avvia un server Modbus TCP (bloccante, un client alla volta).
    .EXAMPLE
        # Avvio base
        Start-ModbusServer -Port 1502

        # Precarica registri e inietta un errore prima di avviare
        Set-HoldingRegister -Address 0 -Value 1234
        Set-ModbusError -FunctionCode 3 -Address 50 -ExceptionCode 0x02
        Start-ModbusServer -Port 1502
    #>
    param(
        [uint16]$Port = 1502,       # 502 richiede privilegi admin
        [string]$Bind = "127.0.0.1"
    )

    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Parse($Bind), $Port)
    $listener.Start()
    Write-Log "Modbus TCP server started on $Bind`:$Port"
    Write-Host ""
    Write-Host "  Keyboard commands (while the server is running):"
    Write-Host "    Ctrl+C   Stop the server and close the connection with FIN (graceful shutdown)"
    Write-Host "    Ctrl+R   Close the current connection with RST (abrupt close, no FIN)"
    Write-Host "    Ctrl+B   Toggle Black Hole: socket open but server ignores everything (simulates silent drop)"
    Write-Host ""
    Write-Host "  Active settings:"
    Write-Host "    Delay           : $(if ($script:GlobalDelayMs -gt 0) { "$($script:GlobalDelayMs) ms" } else { "disabled" })"
    Write-Host "    Idle timeout    : $(if ($script:IdleTimeoutSec -gt 0) { "$($script:IdleTimeoutSec) s" } else { "disabled" })"
    Write-Host "    Disconnect      : $(if ($script:GlobalDisconnect) { "ENABLED" } else { "disabled" })"
    if ($script:ErrorMap.Count -gt 0) {
        Write-Host "    Injected errors :"
        foreach ($kv in $script:ErrorMap.GetEnumerator()) {
            Write-Host "      FC:Addr=$($kv.Key)  ->  Exception=0x$($kv.Value.ToString('X2'))"
        }
    } else {
        Write-Host "    Injected errors : none"
    }
    Write-Host ""

    [byte[]]$buffer = [byte[]]::new(1024)

    try {
        while ($true) {
            Write-Host ""
            Write-Log "Waiting for connection..."
            $acceptTask = $listener.AcceptTcpClientAsync()
            while (-not $acceptTask.Wait(200)) { }
            $client = $acceptTask.Result
            $remote = $client.Client.RemoteEndPoint
            Write-Log "Client connected: $remote"

            $stream = $client.GetStream()
            $stream.ReadTimeout = 30000

            try {
                $lastActivity  = [datetime]::UtcNow
                $rstTriggered  = $false
                $blackHole     = $false
                while ($true) {
                    $readTask   = $stream.ReadAsync($buffer, 0, $buffer.Length)
                    $breakLoop  = $false
                    while (-not $readTask.Wait(200)) {
                        if ($script:IdleTimeoutSec -gt 0 -and -not $blackHole -and
                            ([datetime]::UtcNow - $lastActivity).TotalSeconds -ge $script:IdleTimeoutSec) {
                            Write-Log "  [IDLE TIMEOUT] no request for $($script:IdleTimeoutSec)s, closing connection (FIN)"
                            $breakLoop = $true
                            break
                        }
                        if ([Console]::KeyAvailable) {
                            $key = [Console]::ReadKey($true)
                            if ($key.Key -eq [ConsoleKey]::R -and
                                ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                                Write-Log "  [RST] Ctrl+R: abrupt close, sending RST (no FIN)"
                                $rstTriggered = $true
                                $breakLoop    = $true
                                break
                            }
                            if ($key.Key -eq [ConsoleKey]::B -and
                                ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                                $blackHole = -not $blackHole
                                if ($blackHole) {
                                    Write-Log "  [BLACK HOLE] enabled: socket open, no response (Ctrl+B to exit)"
                                } else {
                                    Write-Log "  [BLACK HOLE] disabled: responding again"
                                    $lastActivity = [datetime]::UtcNow
                                }
                            }
                        }
                    }
                    if ($breakLoop) { break }

                    $read = $readTask.Result
                    if ($read -eq 0) { break }

                    if ($blackHole) {
                        Write-Log "  [BLACK HOLE] RX ignored: $(($buffer[0..($read-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ')"
                        continue
                    }

                    $lastActivity = [datetime]::UtcNow

                    [byte[]]$req = $buffer[0..($read - 1)]
                    Write-Log "  RX: $(($req | ForEach-Object { $_.ToString('X2') }) -join ' ')"

                    $resp = Invoke-HandleRequest $req
                    if ($null -ne $resp) {
                        Write-Log "  TX: $(($resp | ForEach-Object { $_.ToString('X2') }) -join ' ')"
                        $stream.Write($resp, 0, $resp.Length)
                        $stream.Flush()
                    } else {
                        if ($script:GlobalDisconnect) { break }
                    }
                }
            }
            catch [System.IO.IOException] { }
            finally {
                if ($rstTriggered) {
                    # Linger(true,0) = TCP RST immediato, nessun FIN inviato al client
                    $client.Client.LingerState = [System.Net.Sockets.LingerOption]::new($true, 0)
                }
                $client.Close()
                $closeType = if ($rstTriggered) { 'RST' } else { 'FIN' }
                Write-Log "Client disconnected: $remote  [$closeType]"
            }
        }
    }
    finally {
        $listener.Stop()
        Write-Log "Server stopped."
    }
}
