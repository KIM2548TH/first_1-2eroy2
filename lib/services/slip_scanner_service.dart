import 'dart:io';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'image_processor_service.dart';
import 'scan_history_service.dart';

class SlipData {
  final String bank;
  final double amount;
  final DateTime date;
  final String? memo;
  final String? recipient; // Extracted Shop/Recipient Name
  final String? slipImagePath; // Path to the original image file

  SlipData({
    required this.bank, 
    required this.amount, 
    required this.date, 
    this.memo, 
    this.recipient,
    this.slipImagePath,
  });

  @override
  String toString() => 'SlipData(bank: $bank, amount: $amount, date: $date, memo: $memo, recipient: $recipient, path: $slipImagePath)';
  
  Map<String, dynamic> toMap() {
    return {
      'bank': bank,
      'amount': amount,
      'date': date.toIso8601String(),
      'memo': memo,
      'recipient': recipient,
      'slipImagePath': slipImagePath,
    };
  }
}

class SlipScannerService {
  final ScanHistoryService _historyService = ScanHistoryService();
  final ImageProcessorService _imageProcessor = ImageProcessorService();

  Future<List<SlipData>> scanNewSlips() async {
    print("[SlipScanner] Starting scan...");
    
    // 1. Check Permissions
    final PermissionState ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      print("[SlipScanner] Permission denied");
      return [];
    }

    // 2. Get Settings & History
    final selectedAlbumIds = await _historyService.getSelectedAlbumIds();
    final scannedFileIds = await _historyService.getScannedFileIds();
    
    // Strict 1-Month Window
    final now = DateTime.now();
    final cutoffDate = now.subtract(const Duration(days: 30));

    print("[SlipScanner] Scanning images since: $cutoffDate");
    print("[SlipScanner] Selected Albums: ${selectedAlbumIds.isEmpty ? 'ALL (Recent)' : selectedAlbumIds.length}");

    // 3. Query Images
    List<AssetPathEntity> albums = [];
    
    if (selectedAlbumIds.isNotEmpty) {
       // Fetch specific albums
       // Note: PhotoManager doesn't allow fetching by ID directly efficiently without getting all paths first usually,
       // but we can filter the list.
       final allAlbums = await PhotoManager.getAssetPathList(type: RequestType.image);
       albums = allAlbums.where((a) => selectedAlbumIds.contains(a.id)).toList();
    } else {
       // Default to Recent if nothing selected (or maybe user wants nothing? 
       // But for UX, default to Recent is safer for first launch)
       albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        filterOption: FilterOptionGroup(
          createTimeCond: DateTimeCond(
            min: cutoffDate,
            max: now,
          ),
        ),
      );
      if (albums.isNotEmpty) {
        albums = [albums.first]; // Only scan Recent
      }
    }

    if (albums.isEmpty) return [];

    List<SlipData> foundSlips = [];
    List<String> newScannedIds = [];

    try {
      for (final album in albums) {
        final int assetCount = await album.assetCountAsync;
        if (assetCount == 0) continue;

        // Fetch assets (Batch size could be optimized, but let's fetch all for now within range)
        // We need to apply date filter manually if we fetched specific albums without filter option
        // But getAssetListRange doesn't filter by date easily unless we set filterOption on the path.
        // So we'll fetch and check date manually for safety and "Mark as Read" check.
        
        final assets = await album.getAssetListRange(start: 0, end: assetCount);

        for (final asset in assets) {
          // Check "Mark as Read"
          if (scannedFileIds.contains(asset.id)) {
            continue; // Skip already scanned
          }

          // Check Date (Strict)
          if (asset.createDateTime.isBefore(cutoffDate)) {
            continue; // Too old
          }

          File? file = await asset.file;
          if (file == null) continue;

          try {
            final slip = await processImageFile(file);
            
            // Mark as read regardless of result (we processed it)
            newScannedIds.add(asset.id);

            if (slip != null) {
              foundSlips.add(slip);
              print("[SlipScanner] Found Slip: $slip");
            }
          } catch (e) {
            print("[SlipScanner] Error processing file: $e");
          } finally {
            file = null;
          }
        }
      }
    } finally {
      // Save new scanned IDs
      if (newScannedIds.isNotEmpty) {
        await _historyService.addScannedFileIds(newScannedIds);
        print("[SlipScanner] Marked ${newScannedIds.length} files as read.");
      }
    }

    print("[SlipScanner] Scan complete. Found ${foundSlips.length} slips.");
    return foundSlips;
  }

  Future<SlipData?> processImageFile(File file) async {
    print("[DEBUG_IMAGE_PATH] Processing file: ${file.path}");

    // Pre-process Image
    final processedPath = await _imageProcessor.processForOCR(file);

    // Tesseract OCR
    // args: psm 4 = Assume a single column of text of variable sizes.
    // preserve_interword_spaces = 1 to keep spacing.
    final String text = await FlutterTesseractOcr.extractText(
      processedPath, 
      language: 'tha+eng',
      args: {
        "psm": "4",
        "preserve_interword_spaces": "1",
      }
    );

    print("--------------------------------------------------");
    print("[DEBUG_RAW_TEXT] START");
    print(text);
    print("[DEBUG_RAW_TEXT] END");
    print("--------------------------------------------------");

    // 1. Detect Amount (Critical)
    print("[DEBUG_LOGIC] Attempting to detect Amount (Aggressive)...");
    double? amount = _detectAmount(text);
    
    if (amount == null) {
      print("[DEBUG_LOGIC] Amount detection FAILED. Aborting.");
      return null; // Cannot proceed without amount
    }
    print("[DEBUG_LOGIC] Amount Detected: $amount");

    // 2. Detect Bank (Thai Keywords)
    print("[DEBUG_LOGIC] Attempting to detect Bank...");
    String bank = _detectBankThai(text);
    print("[DEBUG_LOGIC] Bank Detected: $bank");

    // 3. Detect Recipient / Shop Name (Dynamic Anchors)
    print("[DEBUG_LOGIC] Attempting to extract Recipient/Shop Name...");
    String? recipient = _extractRecipientName(text);
    if (recipient != null) print("[DEBUG_LOGIC] Recipient Detected: $recipient");

    // 4. Detect Memo (Disabled per user request - User wants to type manually)
    String? memo; // = _detectMemo(text);

    // Date: Use file modification time as proxy
    DateTime date = await file.lastModified();
    print("[DEBUG_LOGIC] Date extracted (from file): $date");

    final slip = SlipData(
      bank: bank, 
      amount: amount, 
      date: date, 
      memo: memo, 
      recipient: recipient,
      slipImagePath: file.path, // Store the path!
    );
    print("[DEBUG_FINAL_OBJECT] Created SlipData: $slip");
    return slip;
  }

  String _detectBankThai(String text) {
    final lowerText = text.toLowerCase();
    
    // Kasikorn
    if (text.contains('กสิกร') || lowerText.contains('kbank') || lowerText.contains('kasikorn')) {
      return 'Kasikorn Bank';
    }

    // SCB
    if (text.contains('ไทยพาณิชย์') || lowerText.contains('scb') || lowerText.contains('siam commercial')) {
      return 'SCB';
    }

    // Krungthai
    if (text.contains('กรุงไทย') || lowerText.contains('krungthai') || lowerText.contains('ktb')) {
      return 'Krungthai Bank';
    }

    // Bangkok Bank
    if (text.contains('กรุงเทพ') || lowerText.contains('bbl') || lowerText.contains('bangkok bank')) {
      return 'Bangkok Bank';
    }

    // GSB
    if (text.contains('ออมสิน') || lowerText.contains('gsb')) {
      return 'GSB';
    }
    
    // TTB
    if (text.contains('ทหารไทย') || text.contains('ธนชาต') || lowerText.contains('ttb')) {
      return 'TTB';
    }

    // TrueMoney
    if (text.contains('ทรูมันนี่') || lowerText.contains('truemoney') || lowerText.contains('true')) {
      return 'TrueMoney Wallet';
    }

    // 7-Eleven
    if (text.contains('7-Eleven') || text.contains('CPALL')) {
      return '7-Eleven';
    }

    return 'Unknown Slip';
  }

  String? _extractRecipientName(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Strategy A: Tax ID Pattern (Line Above)
      // Pattern: (Digits 10-15) e.g., (010753600010286)
      if (RegExp(r'\(\d{10,15}\)').hasMatch(line)) {
        if (i > 0) return _cleanRecipientName(lines[i - 1]);
      }

      // Strategy B: Label Keywords (Line Above)
      if (line.startsWith('รหัสร้านค้า') || line.contains('Merchant ID') ||
          line.startsWith('เลขที่ลูกค้า') || line.contains('Customer ID') ||
          line.startsWith('เลขที่รายการ') || line.contains('Transaction ID')) {
        if (i > 0) return _cleanRecipientName(lines[i - 1]);
      }

      // Strategy C: "To" Anchor (Line Below)
      if (line.contains('ไปยัง') || line.toLowerCase() == 'to' || line.contains('ชำระเงินที่')) {
        if (i + 1 < lines.length) return _cleanRecipientName(lines[i + 1]);
      }
    }
    return null;
  }

  String _cleanRecipientName(String raw) {
    // Remove garbage characters from the start
    // ษ์, Ww, ©, +, |
    String cleaned = raw.replaceAll(RegExp(r'^[ษ์Ww©+|]+'), '').trim();
    return cleaned;
  }

  double? _detectAmount(String text) {
    print("[DEBUG_REGEX] Scanning for aggressive amount patterns...");
    
    final lines = text.split('\n');
    
    // 1. Aggressive Standalone Price Search
    // Pattern: ^[\d,]+\.\d{2}$ (e.g., 50.00, 1,200.50)
    // It must be the ONLY thing on the line (after trimming)
    final aggressiveRegex = RegExp(r'^[\d,]+\.\d{2}$');
    // Pattern for TrueMoney: B 6.00 (Relaxed)
    final trueMoneyRegex = RegExp(r'[B฿]\s*([\d,]+\.\d{2})');

    for (var line in lines) {
      final trimmed = line.trim();
      if (aggressiveRegex.hasMatch(trimmed)) {
        print("[DEBUG_REGEX] Found Aggressive Match: '$trimmed'");
        final amount = _extractNumber(trimmed);
        if (amount != null) return amount;
      }
      
      // Check TrueMoney pattern
      final tmMatch = trueMoneyRegex.firstMatch(trimmed);
      if (tmMatch != null) {
        print("[DEBUG_REGEX] Found TrueMoney Match: '$trimmed'");
        final amountStr = tmMatch.group(1);
        if (amountStr != null) {
          final amount = _extractNumber(amountStr);
          if (amount != null) return amount;
        }
      }
    }

    // 2. Keyword Fallback (Amount, จำนวน, etc.)
    print("[DEBUG_REGEX] No aggressive match. Trying keywords...");
    for (var line in lines) {
      if (line.toLowerCase().contains('amount') || line.contains('จำนวน') || line.contains('บาท')) {
        print("[DEBUG_REGEX] Found keyword in line: '$line'");
        final amount = _extractNumber(line);
        if (amount != null) {
           print("[DEBUG_REGEX] Match Found via Keyword: $amount");
           return amount;
        }
      }
    }

    return null;
  }

  double? _extractNumber(String line) {
    // Remove commas
    final cleanLine = line.replaceAll(',', '');
    // Regex to find floating point numbers
    final RegExp regex = RegExp(r'(\d+\.\d{2})');
    final match = regex.firstMatch(cleanLine);
    if (match != null) {
      return double.tryParse(match.group(1)!);
    }
    return null;
  }

  String? _detectMemo(String text) {
    final lines = text.split('\n');
    for (var line in lines) {
      if (line.contains('บันทึกช่วยจำ') || line.toLowerCase().contains('note') || line.toLowerCase().contains('ref')) {
        // Return the whole line or maybe strip the label
        return line.trim();
      }
    }
    return null;
  }
}
