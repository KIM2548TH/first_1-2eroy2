// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'transaction.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TransactionAdapter extends TypeAdapter<Transaction> {
  @override
  final int typeId = 0;

  @override
  Transaction read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Transaction(
      item: fields[0] as String,
      price: fields[1] as double,
      date: fields[2] as DateTime,
      category: fields[3] as String?,
      qty: fields[4] as double?,
      note: fields[5] as String?,
      slipImagePath: fields[6] as String?,
      type: fields[7] as String?,
      source: fields[8] as String?,
      scannedBank: fields[9] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Transaction obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.item)
      ..writeByte(1)
      ..write(obj.price)
      ..writeByte(2)
      ..write(obj.date)
      ..writeByte(3)
      ..write(obj.category)
      ..writeByte(4)
      ..write(obj.qty)
      ..writeByte(5)
      ..write(obj.note)
      ..writeByte(6)
      ..write(obj.slipImagePath)
      ..writeByte(7)
      ..write(obj.type)
      ..writeByte(8)
      ..write(obj.source)
      ..writeByte(9)
      ..write(obj.scannedBank);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransactionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
