import 'package:hive_flutter/hive_flutter.dart';
import '../models/transaction.dart';
import '../models/chat_message.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Box<Transaction>? _transactionBox;
  Box<ChatMessage>? _chatBox;
  Box? _settingsBox;

  Future<void> init() async {
    await Hive.initFlutter();
    Hive.registerAdapter(TransactionAdapter());
    Hive.registerAdapter(ChatMessageAdapter());
    
    _transactionBox = await Hive.openBox<Transaction>('expenses');
    _chatBox = await Hive.openBox<ChatMessage>('chat_messages');
    _settingsBox = await Hive.openBox('settings');
  }

  Future<void> addTransaction(String item, double price, {String category = 'Uncategorized', double qty = 1.0, DateTime? date, String? note, String? slipImagePath, String type = 'expense', String? source, String? scannedBank}) async {
    final transaction = Transaction(
      item: item,
      price: price,
      date: date ?? DateTime.now(),
      category: category,
      qty: qty,
      note: note,
      slipImagePath: slipImagePath,
      type: type,
      source: source,
      scannedBank: scannedBank,
    );
    await _transactionBox!.add(transaction);
  }

  Future<void> addChatMessage(ChatMessage message) async {
    await _chatBox!.add(message);
  }

  List<Transaction> getAllTransactions() {
    return _transactionBox?.values.toList() ?? [];
  }
  
  List<ChatMessage> getChatHistory() {
    return _chatBox?.values.toList() ?? [];
  }
  
  Box<ChatMessage> get chatBox => _chatBox!;
  Box<Transaction> get transactionBox => _transactionBox!;
  Box get settingsBox => _settingsBox!;
}
