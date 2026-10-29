// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ios_transfer_receipt_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetIosTransferReceiptEntityCollection on Isar {
  IsarCollection<IosTransferReceiptEntity> get iosTransferReceiptEntitys =>
      this.collection();
}

const IosTransferReceiptEntitySchema = CollectionSchema(
  name: r'IosTransferReceiptEntity',
  id: 4342177402679357055,
  properties: {
    r'bytes': PropertySchema(id: 0, name: r'bytes', type: IsarType.long),
    r'committedAt': PropertySchema(
      id: 1,
      name: r'committedAt',
      type: IsarType.dateTime,
    ),
    r'desktopId': PropertySchema(
      id: 2,
      name: r'desktopId',
      type: IsarType.string,
    ),
    r'desktopUserId': PropertySchema(
      id: 3,
      name: r'desktopUserId',
      type: IsarType.string,
    ),
    r'jobId': PropertySchema(id: 4, name: r'jobId', type: IsarType.string),
    r'localSongId': PropertySchema(
      id: 5,
      name: r'localSongId',
      type: IsarType.long,
    ),
    r'operationKey': PropertySchema(
      id: 6,
      name: r'operationKey',
      type: IsarType.string,
    ),
    r'origin': PropertySchema(id: 7, name: r'origin', type: IsarType.string),
    r'pairingId': PropertySchema(
      id: 8,
      name: r'pairingId',
      type: IsarType.string,
    ),
    r'preparedAt': PropertySchema(
      id: 9,
      name: r'preparedAt',
      type: IsarType.dateTime,
    ),
    r'relativePath': PropertySchema(
      id: 10,
      name: r'relativePath',
      type: IsarType.string,
    ),
    r'revision': PropertySchema(id: 11, name: r'revision', type: IsarType.long),
    r'schemaVersion': PropertySchema(
      id: 12,
      name: r'schemaVersion',
      type: IsarType.long,
    ),
    r'serverId': PropertySchema(id: 13, name: r'serverId', type: IsarType.long),
    r'sha256': PropertySchema(id: 14, name: r'sha256', type: IsarType.string),
    r'sourceId': PropertySchema(
      id: 15,
      name: r'sourceId',
      type: IsarType.string,
    ),
    r'state': PropertySchema(id: 16, name: r'state', type: IsarType.string),
  },

  estimateSize: _iosTransferReceiptEntityEstimateSize,
  serialize: _iosTransferReceiptEntitySerialize,
  deserialize: _iosTransferReceiptEntityDeserialize,
  deserializeProp: _iosTransferReceiptEntityDeserializeProp,
  idName: r'id',
  indexes: {
    r'operationKey': IndexSchema(
      id: 1009902635771944155,
      name: r'operationKey',
      unique: true,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'operationKey',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'state': IndexSchema(
      id: 7917036384617311412,
      name: r'state',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'state',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'localSongId': IndexSchema(
      id: -2677976969812078157,
      name: r'localSongId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'localSongId',
          type: IndexType.value,
          caseSensitive: false,
        ),
      ],
    ),
    r'relativePath': IndexSchema(
      id: -3416132874591967176,
      name: r'relativePath',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'relativePath',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _iosTransferReceiptEntityGetId,
  getLinks: _iosTransferReceiptEntityGetLinks,
  attach: _iosTransferReceiptEntityAttach,
  version: '3.3.2',
);

int _iosTransferReceiptEntityEstimateSize(
  IosTransferReceiptEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.desktopId.length * 3;
  {
    final value = object.desktopUserId;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.jobId.length * 3;
  bytesCount += 3 + object.operationKey.length * 3;
  bytesCount += 3 + object.origin.length * 3;
  bytesCount += 3 + object.pairingId.length * 3;
  bytesCount += 3 + object.relativePath.length * 3;
  bytesCount += 3 + object.sha256.length * 3;
  bytesCount += 3 + object.sourceId.length * 3;
  bytesCount += 3 + object.state.length * 3;
  return bytesCount;
}

void _iosTransferReceiptEntitySerialize(
  IosTransferReceiptEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.bytes);
  writer.writeDateTime(offsets[1], object.committedAt);
  writer.writeString(offsets[2], object.desktopId);
  writer.writeString(offsets[3], object.desktopUserId);
  writer.writeString(offsets[4], object.jobId);
  writer.writeLong(offsets[5], object.localSongId);
  writer.writeString(offsets[6], object.operationKey);
  writer.writeString(offsets[7], object.origin);
  writer.writeString(offsets[8], object.pairingId);
  writer.writeDateTime(offsets[9], object.preparedAt);
  writer.writeString(offsets[10], object.relativePath);
  writer.writeLong(offsets[11], object.revision);
  writer.writeLong(offsets[12], object.schemaVersion);
  writer.writeLong(offsets[13], object.serverId);
  writer.writeString(offsets[14], object.sha256);
  writer.writeString(offsets[15], object.sourceId);
  writer.writeString(offsets[16], object.state);
}

IosTransferReceiptEntity _iosTransferReceiptEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = IosTransferReceiptEntity();
  object.bytes = reader.readLong(offsets[0]);
  object.committedAt = reader.readDateTimeOrNull(offsets[1]);
  object.desktopId = reader.readString(offsets[2]);
  object.desktopUserId = reader.readStringOrNull(offsets[3]);
  object.id = id;
  object.jobId = reader.readString(offsets[4]);
  object.localSongId = reader.readLong(offsets[5]);
  object.operationKey = reader.readString(offsets[6]);
  object.origin = reader.readString(offsets[7]);
  object.pairingId = reader.readString(offsets[8]);
  object.preparedAt = reader.readDateTime(offsets[9]);
  object.relativePath = reader.readString(offsets[10]);
  object.revision = reader.readLong(offsets[11]);
  object.schemaVersion = reader.readLong(offsets[12]);
  object.serverId = reader.readLong(offsets[13]);
  object.sha256 = reader.readString(offsets[14]);
  object.sourceId = reader.readString(offsets[15]);
  object.state = reader.readString(offsets[16]);
  return object;
}

P _iosTransferReceiptEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readStringOrNull(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readLong(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readString(offset)) as P;
    case 9:
      return (reader.readDateTime(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readLong(offset)) as P;
    case 12:
      return (reader.readLong(offset)) as P;
    case 13:
      return (reader.readLong(offset)) as P;
    case 14:
      return (reader.readString(offset)) as P;
    case 15:
      return (reader.readString(offset)) as P;
    case 16:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _iosTransferReceiptEntityGetId(IosTransferReceiptEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _iosTransferReceiptEntityGetLinks(
  IosTransferReceiptEntity object,
) {
  return [];
}

void _iosTransferReceiptEntityAttach(
  IsarCollection<dynamic> col,
  Id id,
  IosTransferReceiptEntity object,
) {
  object.id = id;
}

extension IosTransferReceiptEntityByIndex
    on IsarCollection<IosTransferReceiptEntity> {
  Future<IosTransferReceiptEntity?> getByOperationKey(String operationKey) {
    return getByIndex(r'operationKey', [operationKey]);
  }

  IosTransferReceiptEntity? getByOperationKeySync(String operationKey) {
    return getByIndexSync(r'operationKey', [operationKey]);
  }

  Future<bool> deleteByOperationKey(String operationKey) {
    return deleteByIndex(r'operationKey', [operationKey]);
  }

  bool deleteByOperationKeySync(String operationKey) {
    return deleteByIndexSync(r'operationKey', [operationKey]);
  }

  Future<List<IosTransferReceiptEntity?>> getAllByOperationKey(
    List<String> operationKeyValues,
  ) {
    final values = operationKeyValues.map((e) => [e]).toList();
    return getAllByIndex(r'operationKey', values);
  }

  List<IosTransferReceiptEntity?> getAllByOperationKeySync(
    List<String> operationKeyValues,
  ) {
    final values = operationKeyValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'operationKey', values);
  }

  Future<int> deleteAllByOperationKey(List<String> operationKeyValues) {
    final values = operationKeyValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'operationKey', values);
  }

  int deleteAllByOperationKeySync(List<String> operationKeyValues) {
    final values = operationKeyValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'operationKey', values);
  }

  Future<Id> putByOperationKey(IosTransferReceiptEntity object) {
    return putByIndex(r'operationKey', object);
  }

  Id putByOperationKeySync(
    IosTransferReceiptEntity object, {
    bool saveLinks = true,
  }) {
    return putByIndexSync(r'operationKey', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByOperationKey(
    List<IosTransferReceiptEntity> objects,
  ) {
    return putAllByIndex(r'operationKey', objects);
  }

  List<Id> putAllByOperationKeySync(
    List<IosTransferReceiptEntity> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'operationKey', objects, saveLinks: saveLinks);
  }
}

