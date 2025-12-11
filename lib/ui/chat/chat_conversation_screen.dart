import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../providers/app_global_provider.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/constants.dart'; // For ChatMode and Prompts
import '../../models/chat_message.dart';
import '../../services/ai_service.dart';
import '../../services/database_service.dart';
import '../../services/receipt_processor.dart';
import '../../services/scan_history_service.dart';
import '../../services/slip_scanner_service.dart';
import '../../services/category_classifier_service.dart';
import '../widgets/custom_toast.dart';
import '../widgets/slip_card_message.dart';
import '../widgets/ai_expense_card.dart';
import '../widgets/ai_income_card.dart'; // Import Income Card
import '../folder_selection_screen.dart';
import '../../services/theme_service.dart';
import '../widgets/typing_indicator.dart';
import '../../utils/transaction_helper.dart';

class ChatConversationScreen extends StatefulWidget {
  final ChatMode mode;
  final VoidCallback? onBack; // Callback for nested navigation

  const ChatConversationScreen({super.key, required this.mode, this.onBack});

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final TextEditingController _controller = TextEditingController();
  final AIService _aiService = AIService();
  final ScrollController _scrollController = ScrollController();
  final ScanHistoryService _historyService = ScanHistoryService();
  final SlipScannerService _scanner = SlipScannerService();
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _aiService.initialize();
    // No need to inject pending slips anymore, they are in the DB.
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0, // Because we reverse the list
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // Public method called from HomeScreen (Legacy) -> Now internal or via AppBar
  Future<void> scanSlips() async {
    // 1. Check Folder Selection (Restore Original Behavior)
    final selectedAlbumIds = await _historyService.getSelectedAlbumIds();
    if (selectedAlbumIds.isEmpty) {
      // Open Selection Screen
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const FolderSelectionScreen()),
      );
      if (result != true) return; // User cancelled
    }

    // Call the shared scan logic in Provider
    final count = await context.read<AppGlobalProvider>().scanSlips();
    
    if (count > 0) {
      // Scroll to bottom to see new "Reading..." messages
      _scrollToBottom();
    } else {
      if (mounted) {
        showTopRightToast(context, "No new slips found.");
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _controller.clear();
    FocusScope.of(context).unfocus();

    // 1. Add User Message
    final userMsg = ChatMessage(
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
      mode: widget.mode.name, // Save mode
    );
    await DatabaseService().addChatMessage(userMsg);
    _scrollToBottom();

    setState(() {
      _isProcessing = true;
    });

    try {
      // 2. Select Prompt based on Mode
      final String promptTemplate = widget.mode == ChatMode.expense 
          ? AppConstants.kExpenseSystemPrompt 
          : AppConstants.kIncomeSystemPrompt;

      // 3. Process with AI
      final processor = ReceiptProcessor(_aiService);
      final results = await processor.processInputSteps(text, promptTemplate: promptTemplate);

      // 4. Add AI Response Message
      String responseText;
      List<Map<String, dynamic>>? expenseData;
      
      if (widget.mode == ChatMode.expense) {
        if (results.isNotEmpty) {
           responseText = "เจอ ${results.length} รายการครับ ตรวจสอบความถูกต้องแล้วกดบันทึกได้เลย";
           expenseData = results;
        } else {
           responseText = "ไม่พบรายการค่าใช้จ่ายในข้อความครับ";
        }
      } else {
        // Income Mode
        if (results.isNotEmpty) {
           responseText = "เจอรายการรับครับ ตรวจสอบแล้วบันทึกได้เลย";
           expenseData = results; 
        } else {
           responseText = "ไม่พบยอดเงินในข้อความครับ";
        }
      }

      final aiMsg = ChatMessage(
        text: responseText,
        isUser: false,
        timestamp: DateTime.now(),
        expenseData: expenseData,
        mode: widget.mode.name, // Save mode
      );
      await DatabaseService().addChatMessage(aiMsg);

    } catch (e) {
      // Error Message
      final errorMsg = ChatMessage(
        text: "เกิดข้อผิดพลาด: $e",
        isUser: false,
        timestamp: DateTime.now(),
        mode: widget.mode.name, // Save mode
      );
      await DatabaseService().addChatMessage(errorMsg);
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        _scrollToBottom();
      }
    }
  }

  Future<void> _saveExpense(ChatMessage message, int index) async {
    if (message.expenseData == null || message.isSaved) return;

    for (var item in message.expenseData!) {
      if (item['type'] == 'income') {
         await DatabaseService().addTransaction(
           item['source'] ?? 'Income',
           (item['amount'] ?? 0.0).toDouble(),
           category: 'Salary', // Or 'Income'
           qty: 1.0,
           date: message.timestamp,
           type: 'income',
         );
      } else {
         await DatabaseService().addTransaction(
           item['item'],
           item['price'],
           category: item['category'],
           qty: (item['qty'] ?? 1.0).toDouble(),
           date: message.timestamp,
           type: 'expense',
         );
      }
    }

    // Mark as saved
    message.isSaved = true;
    await message.save(); // Save change to Hive

    if (mounted) {
      showTopRightToast(context, 'บันทึกรายการเรียบร้อยแล้ว!');
    }
  }

  Future<void> _saveSlipMessage(ChatMessage message, Map<String, dynamic> slipData) async {
    await TransactionHelper.saveSlipAsTransaction(message, slipData);
    if (mounted) {
      showTopRightToast(context, 'Slip saved!');
    }
  }

  Future<void> _saveAllVerified() async {
    final box = DatabaseService().chatBox;
    final messages = box.values.where((m) => m.imagePath != null && !m.isSaved && m.slipData != null).toList();
    
    int savedCount = 0;
    for (final msg in messages) {
      print('DEBUG: Saving msg index $savedCount with category: ${msg.slipData?['category']}');
      await _saveSlipMessage(msg, Map<String, dynamic>.from(msg.slipData!));
      savedCount++;
    }
    
    if (mounted) {
      showTopRightToast(context, "Saved $savedCount slips!");
    }
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    await message.delete(); // Delete from Hive
    if (mounted) {
      setState(() {}); // Refresh UI
      showTopRightToast(context, "ลบรายการแล้ว");
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = DatabaseService().chatBox;
    final isExpense = widget.mode == ChatMode.expense;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme; // Use standard scheme

    return Scaffold( 
      backgroundColor: theme.scaffoldBackgroundColor, // Match History Tab background
      appBar: AppBar(
        title: Column(
          children: [
            Text(isExpense ? "บันทึกรายจ่าย" : "บันทึกรายรับ"),
            FutureBuilder(
              future: _aiService.initialize(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done) {
                  return const SizedBox.shrink();
                }
                return const Text(
                  "กำลังโหลดโมเดล AI...",
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                );
              },
            ),
          ],
        ),
        backgroundColor: theme.scaffoldBackgroundColor, // Match background
        foregroundColor: colorScheme.onSurface,
        leading: widget.onBack != null ? IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ) : null,
        actions: isExpense ? [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'Scan Slips',
            onPressed: scanSlips,
          ),
        ] : null,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Chat Area
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: box.listenable(),
                  builder: (context, Box<ChatMessage> box, _) {
                    // Filter messages by mode
                    final messages = box.values
                        .where((m) => m.mode == widget.mode.name || (m.mode == null && isExpense)) // Default old msgs to expense
                        .toList()
                        .reversed
                        .toList();

                    // Insert "Thinking" message if processing
                    if (_isProcessing) {
                      messages.insert(0, ChatMessage(
                        text: "AI กำลังคิดอยู่...",
                        isUser: false,
                        timestamp: DateTime.now(),
                      ));
                    }

                    if (messages.isEmpty) {
                      return Center(
                        child: Text(
                          "เริ่มคุยกับ AI ได้เลย...",
                          style: TextStyle(color: Colors.grey[400]),
                        ),
                      );
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      reverse: true, // Show newest at bottom
                      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80), // Extra bottom padding for FAB
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        
                        // Check if it's the temporary "Thinking" message
                        if (_isProcessing && index == 0 && msg.text == "AI กำลังคิดอยู่...") {
                           return Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: theme.brightness == Brightness.dark 
                                      ? const Color(0xFF334155) // Slate 700 for Dark Mode
                                      : colorScheme.secondaryContainer,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(16),
                                    topRight: Radius.circular(16),
                                    bottomRight: Radius.circular(16),
                                    bottomLeft: Radius.circular(4),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      "AI กำลังคิดอยู่",
                                      style: TextStyle(
                                        color: theme.brightness == Brightness.dark 
                                            ? Colors.white 
                                            : colorScheme.onSecondaryContainer,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TypingIndicator(
                                      color: theme.brightness == Brightness.dark 
                                          ? Colors.white 
                                          : colorScheme.onSecondaryContainer,
                                    ),
                                  ],
                                ),
                              ),
                           );
                        }

                        // Check if it's a Slip Message
                        if (msg.imagePath != null) {
                          return SlipCardMessageWidget(
                            message: msg,
                            onSave: _saveSlipMessage,
                            onDelete: _deleteMessage,
                            onCategoryChanged: (newCategory) {
                              // Update the source of truth for "Save All"
                              if (msg.slipData != null && newCategory != null) {
                                print("DEBUG: Updating category for ${msg.imagePath} to $newCategory");
                                // Create a new map to ensure Hive detects the change
                                final newMap = Map<dynamic, dynamic>.from(msg.slipData!);
                                newMap['category'] = newCategory;
                                msg.slipData = newMap;
                                msg.save().then((_) => print("DEBUG: Saved msg.slipData for ${msg.imagePath}")); 
                              }
                            },
                          );
                        }

                        // Check if this is the most recent AI message with data
                        bool isLatestActionable = false;
                        if (!msg.isUser && msg.expenseData != null) {
                           bool hasNewer = false;
                           for (int i = 0; i < index; i++) {
                             if (!messages[i].isUser && messages[i].expenseData != null) {
                               hasNewer = true;
                               break;
                             }
                           }
                           isLatestActionable = !hasNewer;
                        }
                        
                        return _buildMessageBubble(msg, isLatestActionable);
                      },
                    );
                  },
                ),
              ),

              // Input Area
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.cardTheme.color, // Match card color for input area
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      offset: const Offset(0, -2),
                      blurRadius: 5,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: isExpense ? 'พิมพ์รายการจ่าย (เช่น ข้าว 50)' : 'พิมพ์รายรับ (เช่น เงินเดือน 20000)',
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: theme.brightness == Brightness.dark 
                              ? const Color(0xFF0F172A) // Darker input background in dark mode
                              : colorScheme.surfaceVariant, 
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        ),
                        minLines: 1,
                        maxLines: 3,
                        style: TextStyle(color: colorScheme.onSurface),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CircleAvatar(
                      backgroundColor: colorScheme.primary, // Primary color button
                      child: IconButton(
                        icon: Icon(Icons.send, color: colorScheme.onPrimary), // Contrast icon
                        onPressed: _isProcessing ? null : _sendMessage,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Save All FAB (Only for Expense Mode usually, but logic works for both if needed)
          // Currently Save All is for Slips, which are Expense only.
          if (isExpense)
            ValueListenableBuilder(
              valueListenable: box.listenable(),
              builder: (context, Box<ChatMessage> box, _) {
                final unsavedCount = box.values.where((m) => m.imagePath != null && !m.isSaved && m.slipData != null).length;
                
                if (unsavedCount > 0) {
                  return Positioned(
                    bottom: 80, // Above input area
                    right: 16,
                    child: FloatingActionButton.extended(
                      onPressed: _saveAllVerified,
                      label: Text("Save All ($unsavedCount)"),
                      icon: const Icon(Icons.save_alt),
                      backgroundColor: colorScheme.tertiaryContainer,
                      foregroundColor: colorScheme.onTertiaryContainer,
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isLatestActionable) {
    final isUser = msg.isUser;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Custom Colors for Better Contrast
    final userBubbleColor = colorScheme.primary;
    final aiBubbleColor = isDark 
        ? const Color(0xFF334155) // Slate 700 (Lighter than bg)
        : colorScheme.secondaryContainer;
    
    final userTextColor = colorScheme.onPrimary;
    final aiTextColor = isDark 
        ? Colors.white 
        : colorScheme.onSecondaryContainer;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isUser ? userBubbleColor : aiBubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(4),
                  bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(16),
                ),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 2, offset: const Offset(0, 1))
                ],
              ),
              child: Text(
                msg.text,
                style: TextStyle(
                  color: isUser ? userTextColor : aiTextColor,
                ),
              ),
            ),
            
            // Result Card (Only for AI messages with data)
            if (!isUser && msg.expenseData != null && msg.expenseData!.isNotEmpty)
              // Check type of first item to decide widget
              (msg.expenseData![0]['type'] == 'income')
                  ? AIIncomeCardWidget(
                      message: msg,
                      onSave: (m) => _saveExpense(m, 0),
                      onDelete: _deleteMessage,
                    )
                  : AIExpenseCardWidget(
                      message: msg,
                      onSave: (m) => _saveExpense(m, 0),
                      onDelete: _deleteMessage,
                    ),
              
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
              child: Text(
                DateFormat('HH:mm').format(msg.timestamp),
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
