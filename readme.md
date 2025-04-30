# Log Manager Tool

## Overview

The **Log Manager Tool** is a PowerShell-based application designed to manage log files efficiently. It provides a graphical user interface (GUI) for performing common log management tasks such as compressing logs, viewing logs, and searching logs by keywords. The tool supports handling large volumes of log files and integrates with 7-Zip for advanced compression capabilities.

---

## Features

### 1. **Compress Logs**
- Compresses old log files into `.7z` or `.gz` archives to save disk space.
- Supports batch compression by date for efficient processing.
- Automatically rotates old archives based on configurable retention policies.
- Uses 7-Zip for high compression ratios (requires `7za.exe`).

### 2. **View Logs**
- Displays log files within a specified date range.
- Supports viewing logs from both the main directory and archived files (`.gz`, `.7z`, `.zip`).
- Automatically extracts and processes compressed log files for viewing.
- Beautifies log content for better readability.

### 3. **Search Logs**
- Searches log files for specific keywords within a specified date range.
- Supports searching in both plain text and compressed log files (`.gz`, `.7z`, `.zip`).
- Displays search results with line numbers and matching content.
- Allows exporting search results to a file.

---

## Project Structure

LogManagerTool/
├── CompressLogs.ps1         # Handles log compression and archive management
├── LogManagerGUI.ps1        # Main GUI logic and event handling
├── LogManagerGUI.xaml       # XAML file defining the GUI layout
├── SearchLogs.ps1           # Implements log search functionality
├── ViewLogs.ps1             # Implements log viewing functionality
├── Main.ps1                 # Entry point for launching the GUI
├── README.md                # Documentation explaining the project and its features
├── tools/
│   └── 7zip/                # Contains 7-Zip command-line tool (7za.exe)
│       ├── 7za.exe          # 7-Zip executable for compression
│       ├── license.txt      # License information for 7-Zip
│       ├── readme.txt       # Documentation for 7-Zip
│       └── 7-zip.chm        # User manual for 7-Zip


## How to Use

### 1. **Launch the Tool**
- Run `LogManagerGUI.ps1` or `Main.ps1` to start the Log Manager Tool GUI.

### 2. **Select an Action**
- Choose one of the following actions from the dropdown menu:
  - **Compress Logs**: Compress old log files.
  - **View Logs**: View log files within a date range.
  - **Search Logs**: Search log files for specific keywords.

### 3. **Specify Log Folder**
- Use the "Browse" button to select the folder containing log files.

### 4. **Set Additional Parameters**
- **Keyword**: Enter a keyword for searching logs (only for "Search Logs").
- **Start Date** and **End Date**: Specify the date range for viewing or searching logs.

### 5. **Run the Action**
- Click the "Run" button to execute the selected action.
- Progress is displayed in the progress bar.

### 6. **Export Results**
- Use the "Export Results" button to save filtered logs or search results to a `.zip` file.

---

## Requirements

- **PowerShell**: Version 5.1 or later.
- **7-Zip**: The tool includes a portable version of 7-Zip (`7za.exe`) for compression.
    Note: If 7-Zip is not found in the directory, a portable version of 7-Zip will be automatically downloaded to the `tools\7zip` directory.

---

## Technical Details

### Compression
- Uses the `Compress-OldLogs` function in `CompressLogs.ps1` to compress log files.
- Supports both `.7z` and `.gz` formats.
- Automatically deletes old archives based on retention policies.

### Viewing Logs
- Uses the `Get-LogContent` function in `ViewLogs.ps1` to display logs.
- Extracts and processes compressed files (`.gz`, `.7z`, `.zip`) for viewing.

### Searching Logs
- Uses the `Search-LogsByKeyword` function in `SearchLogs.ps1` to search logs.
- Supports searching in both plain text and compressed files.

---

## Limitations

- The tool may experience performance issues with extremely large log directories.

---