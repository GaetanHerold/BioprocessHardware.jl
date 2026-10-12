# Laboratory Hardware Quickstart Guide (Benchtop Logging)

This guide provides simple, step-by-step instructions for anyone (researchers, technicians, students) who needs to **plug in a laboratory instrument and log data into a CSV/Excel file** on a laptop or desktop computer.

---

## 1. First-Time System Setup (2 Minutes)

### Linux (Ubuntu, Debian, Mint, Fedora)
By default, Linux blocks regular users from reading USB serial ports. You only need to run this command **once** on your laptop:

```bash
sudo usermod -aG dialout $USER
```
> **Important**: After running this command, **log out and log back in** (or restart your laptop) for the permissions to take effect.

### Windows
Instruments will appear automatically as `COM3`, `COM4`, etc. Windows 10/11 automatically installs the virtual COM port drivers for Silicon Labs CP210x (Voltcraft) and Numato CDC.

### macOS
No special drivers or permissions are required. Instruments appear automatically under `/dev/cu.usb*`.

---

## 2. Step 1: Scan & Discover Connected Hardware

Plug your USB or Ethernet cable into your laptop, open a terminal in this repository, and run:

```bash
julia tools/scan_hardware.jl
```

The scanner will check your OS permissions and display an automated report:

```text
════════════════════════════════════════════════════════════════════════════
 BIOPROCESS HARDWARE DIAGNOSTIC & DISCOVERY SCANNER
════════════════════════════════════════════════════════════════════════════
  OS Platform:       Linux (x86_64)
  Serial Perms:      OK (User is in dialout group)
----------------------------------------------------------------------------
Instrument Name                      │ Port          │ Status     │ Suggested Command
----------------------------------------------------------------------------
Voltcraft DPPS-16-30 (Power Supply)  │ /dev/ttyUSB0  │ ✓ ONLINE   │ julia scripts/bench/log_power_supply.jl
Numato Lab USB ADC / Relay           │ None detected │ - NOT FOUND│ julia scripts/bench/log_adc_sensors.jl
ESP32-S3 Microcontroller             │ None detected │ - NOT FOUND│ julia scripts/bench/log_mcu_stream.jl
Eppendorf BioFlo 120 / 320           │ 192.168.1.100 │ - NOT FOUND│ julia scripts/bench/log_bioflo.jl
----------------------------------------------------------------------------
```

---

## 3. Step 2: Running Benchtop Loggers

### A. Voltcraft DPPS-16-30 DC Power Supply

* **Physical Connection**: Connect a USB-B cable to the rear USB port of the power supply and USB-A to your laptop.
* **Launch Logger**:
  ```bash
  julia scripts/bench/log_power_supply.jl
  ```
* **Optional Flags**:
  ```bash
  # Specify custom port
  julia scripts/bench/log_power_supply.jl --port /dev/ttyUSB0

  # Change logging interval (e.g. every 5 seconds)
  julia scripts/bench/log_power_supply.jl --interval 5.0

  # Specify custom output file path
  julia scripts/bench/log_power_supply.jl --csv ~/Desktop/my_experiment.csv
  ```
* **Live Display**:
  ```text
  Timestamp               │ Voltage   │ Current   │ Power     │ Mode
  --------------------------------------------------------------------
  2026-10-12 16:15:02.120 │   12.00 V │    3.50 A │   42.00 W │ CV  
  2026-10-12 16:15:03.121 │   12.01 V │    3.49 A │   41.91 W │ CV  
  ```
* **Output Data**: Saved automatically to `experiments/power_logs/power_log_<YYYYMMDD_HHMMSS>.csv`. Open directly in LibreOffice Calc or Microsoft Excel.
* **To Stop**: Press `Ctrl + C` in the terminal.

---

### B. Numato Lab USB ADC & 4–20 mA Sensors

* **Physical Connection**: Connect USB cable from the Numato relay/ADC module to your computer.
* **Launch Logger**:
  ```bash
  julia scripts/bench/log_adc_sensors.jl
  ```
* **What it logs**: Raw 10-bit ADC counts (0–1023) and calibrated loop current ($4.00 - 20.00\text{ mA}$) across burden resistors.
* **Output Data**: Saved to `experiments/sensor_logs/adc_sensors_log_<timestamp>.csv`.

---

### C. ESP32-S3 Pilot Plant Microcontroller

* **Physical Connection**: USB-C cable to the ESP32-S3 developer board.
* **Launch Logger**:
  ```bash
  julia scripts/bench/log_mcu_stream.jl
  ```
* **What it logs**: 30-field ASCII telemetry including fermenter pH, extraction pH, power supply voltage ($V$), stack current ($A$), pump setpoints, and vessel temperatures.
* **Output Data**: Saved to `experiments/mcu_logs/mcu_stream_log_<timestamp>.csv`.

---

### D. Eppendorf BioFlo 120 / 320 Bioreactor

* **Physical Connection**: Standard RJ45 Ethernet cable connected directly between your laptop and the BioFlo Ethernet port (or via a local lab network switch).
* **Laptop Network Setting**: Set your laptop Ethernet adapter to static IP `192.168.1.50` (Subnet `255.255.255.0`).
* **Launch Logger**:
  ```bash
  julia scripts/bench/log_bioflo.jl --host 192.168.1.100
  ```
* **What it logs**: Dissolved Oxygen ($d\text{O}_2\ [\%]$), pH, Temperature ($^\circ\text{C}$), Agitation ($\text{rpm}$), and Peristaltic Pump 1 speed ($\text{rpm}$).
* **Output Data**: Saved to `experiments/bioflo_logs/bioflo_log_<timestamp>.csv`.

---

## 4. Standalone Setup (Without the Full LUCRA Pilot Repository)

If a colleague wants to use the power supply logger on their laptop **without** downloading the entire LUCRA control repository and scientific simulation packages:

1. Clone only the lightweight hardware package:
   ```bash
   git clone https://github.com/GaetanHerold/BioprocessHardware.jl.git
   cd BioprocessHardware.jl
   ```
2. Initialize dependencies (takes ~15 seconds):
   ```bash
   julia --project=. -e 'using Pkg; Pkg.instantiate()'
   ```
3. Run the standalone bench logger:
   ```bash
   julia --project=. examples/log_power_supply.jl
   ```

---

## 5. Troubleshooting & FAQ

| Problem | Cause | Solution |
| :--- | :--- | :--- |
| **`Permission denied: /dev/ttyUSB0`** | User is not in the Linux serial group | Run `sudo usermod -aG dialout $USER`, then log out and log back in. |
| **`Port busy or cannot be opened`** | Another application is using the port | Close any Arduino IDE, serial monitor, or browser dashboard holding the COM port. |
| **Script says "MOCK SIMULATION mode"** | Cable is unplugged or wrong port specified | Check the USB cable connection. Run `julia tools/scan_hardware.jl` to confirm the port name. |
| **Numbers in Excel are all in one column** | CSV separator locale mismatch | In Excel, select column A, click **Data** $\to$ **Text to Columns**, select **Delimited**, and check **Comma**. |
