# PsModbusTcpServer — Server Modbus TCP in PowerShell

> 🇬🇧 [Read in English](README.md)

Server Modbus TCP minimale per testare client e librerie in modo controllato.
Un client alla volta, bloccante. Non richiede dipendenze esterne.

---

## Avvio rapido

```powershell
# 1. Carica le funzioni in memoria (dot-source obbligatorio)
. .\PsModbusTcpServer.ps1

# 2. (Opzionale) Precarica valori nei registri
Set-HoldingRegister -Address 0 -Value 1234

# 3. (Opzionale) Configura errori da iniettare
Set-ModbusError -FunctionCode 3 -Address 99 -ExceptionCode 0x02

# 4. Avvia il server — si blocca qui in ascolto, Ctrl+C per fermare
Start-ModbusServer -Port 1502
```

La porta 502 (standard Modbus) richiede privilegi admin. Usa una porta alta (es. 1502) per i test.

---

## Function Code supportati

| FC   | Descrizione              |
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

## Banchi di memoria

Il server mantiene in memoria quattro banchi indipendenti, tutti di dimensione 65536:

| Banco             | Tipo     | FC lettura | FC scrittura |
|-------------------|----------|------------|--------------|
| Holding Registers | uint16   | 0x03       | 0x06, 0x10   |
| Input Registers   | uint16   | 0x04       | solo via API |
| Coils             | bool     | 0x01       | 0x05, 0x0F   |
| Discrete Inputs   | bool     | 0x02       | solo via API |

I banchi Input Registers e Discrete Inputs sono in sola lettura via protocollo Modbus;
puoi scriverli solo tramite le funzioni PowerShell (utile per simulare sensori).

---

## API PowerShell

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

## Iniezione errori

Puoi far rispondere il server con un'eccezione Modbus invece della risposta normale.
Utile per testare come la tua libreria gestisce gli errori.

### Codici eccezione Modbus comuni
| Codice | Significato             |
|--------|-------------------------|
| 0x01   | Illegal Function        |
| 0x02   | Illegal Data Address    |
| 0x03   | Illegal Data Value      |
| 0x04   | Slave Device Failure    |

### Comandi
```powershell
# Errore su FC + indirizzo specifico
Set-ModbusError -FunctionCode 3 -Address 100 -ExceptionCode 0x02

# Errore su qualsiasi indirizzo di un FC
Set-ModbusFunctionError -FunctionCode 3 -ExceptionCode 0x01

# Rimuovi un errore specifico
Clear-ModbusError -FunctionCode 3 -Address 100

# Rimuovi tutti gli errori iniettati
Clear-AllModbusErrors
```

---

## Disconnessione simulata

Quando abilitata, il server chiude la connessione TCP senza rispondere su **qualsiasi** richiesta.
Utile per testare come la tua libreria reagisce a una disconnessione brusca.

```powershell
Enable-ModbusDisconnect   # attiva
Disable-ModbusDisconnect  # disattiva
```

---

## Idle timeout

Chiude la connessione se non arrivano richieste Modbus entro N secondi dall'ultima.
Simula il comportamento di dispositivi reali che chiudono le connessioni inattive.
I TCP keepalive del client **non** resettano il timer: solo le richieste Modbus lo resettano.

```powershell
Set-ModbusIdleTimeout -Seconds 30   # chiude dopo 30s senza richieste
Clear-ModbusIdleTimeout             # disattiva il timeout
```

---

## Black Hole

Il server mantiene la connessione TCP aperta ma **ignora silenziosamente** tutte le richieste,
senza inviare alcuna risposta. Utile per simulare uno "silent drop" e testare il timeout del client.

Si attiva e disattiva a caldo con `Ctrl+B` mentre il server è in ascolto.

```
  [BLACK HOLE] enabled: socket open, no response (Ctrl+B to exit)
  [BLACK HOLE] RX ignored: 00 01 00 00 00 06 01 03 00 00 00 01
  [BLACK HOLE] disabled: responding again
```

---

## Delay globale

Ritarda la risposta di N millisecondi su **qualsiasi** richiesta.
Se N supera il timeout del tuo client, il client va in timeout.

```powershell
Set-ModbusDelay -DelayMs 3000   # risponde dopo 3 secondi
Set-ModbusDelay -DelayMs 10000  # causa timeout se il client ha timeout < 10s
Clear-ModbusDelay               # rimuove il delay
```

Delay e disconnessione possono essere attivi insieme: il delay viene applicato prima,
poi la connessione viene chiusa senza inviare nulla.

---

## Output in console

> **Nota:** i messaggi dello script sono in inglese.

Ogni riga è prefissata con l'orario `[HH:mm:ss]`. Esempio di sessione completa:

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

- **RX** — frame grezzo ricevuto dalla libreria (MBAP header + PDU, in hex)
- **TX** — frame grezzo inviato in risposta (in hex)
- **[READ]** — valori letti, mostrati in decimale, hex e binario
- **[WRITE]** — valori scritti dalla libreria, stessa formattazione
- **[INJECT]** — quando scatta un errore Modbus iniettato
- **[DISCONNECT]** — quando la disconnessione simulata è attiva
- **[DELAY]** — quando il delay globale è attivo
- **[IDLE TIMEOUT]** — quando la connessione viene chiusa per inattività
- **[BLACK HOLE]** — quando la modalità Black Hole è attiva
- **[WARN]** — FC ricevuto ma non supportato

### Esempio scrittura registro
```
  [WRITE] HR[5] = 65535  (0xFFFF | 0b1111111111111111)
```

### Esempio lettura coil
```
  [READ]  Coil[0..2]
          [0] = ON  (1)
          [1] = OFF (0)
          [2] = ON  (1)
```

### Esempio errore iniettato
```
  [INJECT] FC=0x03 Addr=100 -> Exception=0x02
```

### Esempio disconnessione simulata
```
  [DISCONNECT] closing connection
```

### Esempio delay
```
  [DELAY] 3000ms before responding...
```

### Esempio idle timeout
```
  [IDLE TIMEOUT] no request for 30s, closing connection (FIN)
```

### Esempio black hole
```
  [BLACK HOLE] enabled: socket open, no response (Ctrl+B to exit)
  [BLACK HOLE] RX ignored: 00 01 00 00 00 06 01 03 00 00 00 01
```

---

## Comandi da tastiera (runtime)

Mentre `Start-ModbusServer` è in esecuzione:

| Tasto  | Effetto                                                                              |
|--------|--------------------------------------------------------------------------------------|
| Ctrl+C | Ferma il server; chiude la connessione corrente con FIN (chiusura ordinata)          |
| Ctrl+R | Chiude la connessione corrente con RST (chiusura brusca, senza FIN)                  |
| Ctrl+B | Attiva / disattiva **Black Hole**: socket aperta, richieste ignorate silenziosamente |

---

## Parametri di Start-ModbusServer

```powershell
Start-ModbusServer -Port 1502 -Bind "127.0.0.1"
```

| Parametro | Default       | Note                                         |
|-----------|---------------|----------------------------------------------|
| Port      | 1502          | Porta TCP in ascolto                         |
| Bind      | "127.0.0.1"   | Usa "0.0.0.0" per accettare da rete esterna  |
