# PsModbusTcpServer — Modbus TCP Server in PowerShell

> 🇮🇹 [Leggi in italiano](it/README.md)

Minimal Modbus TCP server for testing clients and libraries in a controlled environment.
Single client, blocking. No external dependencies required.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/andreatondelli)

---

## Quick start

```powershell
# 1. Load functions into memory (dot-source required)
. .\PsModbusTcpServer.ps1

# 2. (Optional) Pre-load register values
Set-HoldingRegister -Address 0 -Value 1234

# 3. (Optional) Configure errors to inject
Set-ModbusError -FunctionCode 3 -Address 99 -ExceptionCode 0x02

# 4. Start the server — blocks here, Ctrl+C to stop
Start-ModbusServer -Port 1502
```

Port 502 (standard Modbus) requires admin privileges. Use a high port (e.g. 1502) for testing.

---

## Supported Function Codes

| FC   | Description              |
|------|--------------------------|
| 0x01 | Read Coils               |
| 0x02 | Read Discrete Inputs     |
| 0x03 | Read Holding Registers   |
| 0x04 | Read Input Registers     |
| 0x05 | Write Single Coil        |
| 0x06 | Write Single Register    |
| 0x0F | Write Multiple Coils     |
| 0x10 | Write Multiple Registers |

---

## Memory banks

The server maintains four independent banks in memory, each of size 65536:

| Bank              | Type     | Read FC    | Write FC     |
|-------------------|----------|------------|--------------|
| Holding Registers | uint16   | 0x03       | 0x06, 0x10   |
| Input Registers   | uint16   | 0x04       | API only     |
| Coils             | bool     | 0x01       | 0x05, 0x0F   |
| Discrete Inputs   | bool     | 0x02       | API only     |

Input Registers and Discrete Inputs are read-only via the Modbus protocol;
you can write them only through the PowerShell API (useful for simulating sensors).

All addresses from 0 to 65535 are accepted without validation: the server never replies with
"Illegal Data Address" unless you explicitly inject that error via `Set-ModbusError`.
Values written by a client are stored in RAM and returned by subsequent reads — the server
is stateful for the entire duration of the process.

---

## PowerShell API

### Holding Registers
```powershell
Set-HoldingRegister -Address 10 -Value 1234
Get-HoldingRegister -Address 10
```

### Input Registers
```powershell
Set-InputRegister -Address 5 -Value 999
Get-InputRegister -Address 5
```

### Coils
```powershell
Set-Coil -Address 0 -Value $true
Get-Coil -Address 0
```

### Discrete Inputs
```powershell
Set-DiscreteInput -Address 20 -Value $true
Get-DiscreteInput -Address 20
```

---

## Error injection

You can make the server reply with a Modbus exception instead of the normal response.
Useful for testing how your library handles errors.

### Common Modbus exception codes
| Code | Meaning                 |
|------|-------------------------|
| 0x01 | Illegal Function        |
| 0x02 | Illegal Data Address    |
| 0x03 | Illegal Data Value      |
| 0x04 | Slave Device Failure    |

### Commands
```powershell
# Error on a specific FC + address
Set-ModbusError -FunctionCode 3 -Address 100 -ExceptionCode 0x02

# Error on any address of a FC
Set-ModbusFunctionError -FunctionCode 3 -ExceptionCode 0x01

# Remove a specific error
Clear-ModbusError -FunctionCode 3 -Address 100

# Remove all injected errors
Clear-AllModbusErrors
```

---

## Simulated disconnect

When enabled, the server closes the TCP connection without responding to **any** request.
Useful for testing how your library handles an abrupt disconnection.

```powershell
Enable-ModbusDisconnect   # enable
Disable-ModbusDisconnect  # disable
```

---

## Idle timeout

Closes the connection if no Modbus request arrives within N seconds of the last one.
Simulates the behavior of real devices that close idle connections.
TCP keepalives from the client do **not** reset the timer: only Modbus requests do.

```powershell
Set-ModbusIdleTimeout -Seconds 30   # close after 30s of inactivity
Clear-ModbusIdleTimeout             # disable the timeout
```

---

## Black Hole

The server keeps the TCP connection open but **silently ignores** all requests,
sending no response. Useful for simulating a silent drop and testing client timeouts.

Toggle on/off with `Ctrl+B` while the server is running.

```
  [BLACK HOLE] enabled: socket open, no response (Ctrl+B to exit)
  [BLACK HOLE] RX ignored: 00 01 00 00 00 06 01 03 00 00 00 01
  [BLACK HOLE] disabled: responding again
```

---

## Global delay

Delays the response by N milliseconds on **any** request.
If N exceeds your client's timeout, the client will time out.

```powershell
Set-ModbusDelay -DelayMs 3000   # respond after 3 seconds
Set-ModbusDelay -DelayMs 10000  # causes timeout if client timeout < 10s
Clear-ModbusDelay               # remove the delay
```

Delay and disconnect can be active at the same time: the delay is applied first,
then the connection is closed without sending anything.

---

## Console output

Every line is prefixed with the time `[HH:mm:ss]`. Full session example:

```
[14:00:00] Modbus TCP server started on 127.0.0.1:1502

  Keyboard commands (while the server is running):
    Ctrl+C   Stop the server and close the connection with FIN (graceful shutdown)
    Ctrl+R   Close the current connection with RST (abrupt close, no FIN)
    Ctrl+B   Toggle Black Hole: socket open but server ignores everything (simulates silent drop)

  Active settings:
    Delay           : disabled
    Idle timeout    : disabled
    Disconnect      : disabled
    Injected errors : none

[14:00:01] Waiting for connection...
[14:00:02] Client connected: 127.0.0.1:54321
[14:00:02]   RX: 00 01 00 00 00 06 01 03 00 00 00 03
[14:00:02]   [READ]  HR[0..2]
            [0] = 1234  (0x04D2 | 0b0000010011010010)
            [1] =    0  (0x0000 | 0b0000000000000000)
            [2] =   42  (0x002A | 0b0000000000101010)
[14:00:02]   TX: 00 01 00 00 00 09 01 03 06 04 D2 00 00 00 2A
```

- **RX** — raw frame received (MBAP header + PDU, hex)
- **TX** — raw frame sent in response (hex)
- **[READ]** — values read, shown in decimal, hex and binary
- **[WRITE]** — values written by the client, same format
- **[INJECT]** — when an injected Modbus error fires
- **[DISCONNECT]** — when simulated disconnect is active
- **[DELAY]** — when global delay is active
- **[IDLE TIMEOUT]** — when the connection is closed due to inactivity
- **[BLACK HOLE]** — when Black Hole mode is active
- **[WARN]** — FC received but not supported

### Write register example
```
  [WRITE] HR[5] = 65535  (0xFFFF | 0b1111111111111111)
```

### Read coil example
```
  [READ]  Coil[0..2]
          [0] = ON  (1)
          [1] = OFF (0)
          [2] = ON  (1)
```

### Injected error example
```
  [INJECT] FC=0x03 Addr=100 -> Exception=0x02
```

### Simulated disconnect example
```
  [DISCONNECT] closing connection
```

### Delay example
```
  [DELAY] 3000ms before responding...
```

### Idle timeout example
```
  [IDLE TIMEOUT] no request for 30s, closing connection (FIN)
```

### Black hole example
```
  [BLACK HOLE] enabled: socket open, no response (Ctrl+B to exit)
  [BLACK HOLE] RX ignored: 00 01 00 00 00 06 01 03 00 00 00 01
```

---

## Keyboard shortcuts (runtime)

While `Start-ModbusServer` is running:

| Key    | Effect                                                                              |
|--------|-------------------------------------------------------------------------------------|
| Ctrl+C | Stop the server; closes the current connection with FIN (graceful)                  |
| Ctrl+R | Close the current connection with RST (abrupt, no FIN)                              |
| Ctrl+B | Toggle **Black Hole**: socket open, requests silently ignored                       |

---

## Start-ModbusServer parameters

```powershell
Start-ModbusServer -Port 1502 -Bind "127.0.0.1"
```

| Parameter | Default       | Notes                                          |
|-----------|---------------|------------------------------------------------|
| Port      | 1502          | TCP listening port                             |
| Bind      | "127.0.0.1"   | Use "0.0.0.0" to accept from external network  |
