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

extension IosTransferReceiptEntityQueryWhereSort
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QWhere
        > {
  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterWhere>
  anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterWhere>
  anyLocalSongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'localSongId'),
      );
    });
  }
}

extension IosTransferReceiptEntityQueryWhere
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QWhereClause
        > {
  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  operationKeyEqualTo(String operationKey) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(
          indexName: r'operationKey',
          value: [operationKey],
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  operationKeyNotEqualTo(String operationKey) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'operationKey',
                lower: [],
                upper: [operationKey],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'operationKey',
                lower: [operationKey],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'operationKey',
                lower: [operationKey],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'operationKey',
                lower: [],
                upper: [operationKey],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  stateEqualTo(String state) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'state', value: [state]),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  stateNotEqualTo(String state) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'state',
                lower: [],
                upper: [state],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'state',
                lower: [state],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'state',
                lower: [state],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'state',
                lower: [],
                upper: [state],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  localSongIdEqualTo(int localSongId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(
          indexName: r'localSongId',
          value: [localSongId],
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  localSongIdNotEqualTo(int localSongId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'localSongId',
                lower: [],
                upper: [localSongId],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'localSongId',
                lower: [localSongId],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'localSongId',
                lower: [localSongId],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'localSongId',
                lower: [],
                upper: [localSongId],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  localSongIdGreaterThan(int localSongId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'localSongId',
          lower: [localSongId],
          includeLower: include,
          upper: [],
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  localSongIdLessThan(int localSongId, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'localSongId',
          lower: [],
          upper: [localSongId],
          includeUpper: include,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  localSongIdBetween(
    int lowerLocalSongId,
    int upperLocalSongId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.between(
          indexName: r'localSongId',
          lower: [lowerLocalSongId],
          includeLower: includeLower,
          upper: [upperLocalSongId],
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  relativePathEqualTo(String relativePath) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(
          indexName: r'relativePath',
          value: [relativePath],
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterWhereClause
  >
  relativePathNotEqualTo(String relativePath) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'relativePath',
                lower: [],
                upper: [relativePath],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'relativePath',
                lower: [relativePath],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'relativePath',
                lower: [relativePath],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'relativePath',
                lower: [],
                upper: [relativePath],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension IosTransferReceiptEntityQueryFilter
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QFilterCondition
        > {
  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  bytesEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bytes', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  bytesGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bytes',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  bytesLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bytes',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  bytesBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bytes',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'committedAt'),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'committedAt'),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'committedAt', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtGreaterThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'committedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtLessThan(DateTime? value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'committedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  committedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'committedAt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'desktopId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'desktopId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'desktopId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'desktopId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'desktopId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNull(property: r'desktopUserId'),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        const FilterCondition.isNotNull(property: r'desktopUserId'),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdEqualTo(String? value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'desktopUserId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'desktopUserId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'desktopUserId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'desktopUserId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  desktopUserIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'desktopUserId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  idLessThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'jobId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'jobId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'jobId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'jobId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  jobIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'jobId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  localSongIdEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'localSongId', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  localSongIdGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'localSongId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  localSongIdLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'localSongId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  localSongIdBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'localSongId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'operationKey',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'operationKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'operationKey',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'operationKey', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  operationKeyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'operationKey', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'origin',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'origin',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'origin',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'origin', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  originIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'origin', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'pairingId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'pairingId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'pairingId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'pairingId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  pairingIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'pairingId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  preparedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'preparedAt', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  preparedAtGreaterThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'preparedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  preparedAtLessThan(DateTime value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'preparedAt',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  preparedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'preparedAt',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'relativePath',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'relativePath',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'relativePath',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'relativePath', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  relativePathIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'relativePath', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  revisionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'revision', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  revisionGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'revision',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  revisionLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'revision',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  revisionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'revision',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  schemaVersionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'schemaVersion', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  schemaVersionGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'schemaVersion',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  schemaVersionLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'schemaVersion',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  schemaVersionBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'schemaVersion',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  serverIdEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'serverId', value: value),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  serverIdGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'serverId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  serverIdLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'serverId',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  serverIdBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'serverId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256EqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256GreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256LessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256Between(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'sha256',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256StartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256EndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256Contains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'sha256',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256Matches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'sha256',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256IsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'sha256', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sha256IsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'sha256', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'sourceId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'sourceId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'sourceId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'sourceId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  sourceIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'sourceId', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'state',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'state',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'state',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'state', value: ''),
      );
    });
  }

  QueryBuilder<
    IosTransferReceiptEntity,
    IosTransferReceiptEntity,
    QAfterFilterCondition
  >
  stateIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'state', value: ''),
      );
    });
  }
}

extension IosTransferReceiptEntityQueryObject
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QFilterCondition
        > {}

extension IosTransferReceiptEntityQueryLinks
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QFilterCondition
        > {}

extension IosTransferReceiptEntityQuerySortBy
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QSortBy
        > {
  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByBytes() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bytes', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByBytesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bytes', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByCommittedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'committedAt', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByCommittedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'committedAt', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByDesktopId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByDesktopIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByDesktopUserId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopUserId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByDesktopUserIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopUserId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByJobId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'jobId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByJobIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'jobId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByLocalSongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localSongId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByLocalSongIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localSongId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByOperationKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'operationKey', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByOperationKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'operationKey', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByOrigin() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'origin', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByOriginDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'origin', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByPairingId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'pairingId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByPairingIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'pairingId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByPreparedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'preparedAt', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByPreparedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'preparedAt', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByRelativePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'relativePath', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByRelativePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'relativePath', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByRevision() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'revision', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByRevisionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'revision', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByServerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByServerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySha256() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sha256', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySha256Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sha256', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySourceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sourceId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortBySourceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sourceId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByState() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  sortByStateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.desc);
    });
  }
}

extension IosTransferReceiptEntityQuerySortThenBy
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QSortThenBy
        > {
  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByBytes() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bytes', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByBytesDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bytes', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByCommittedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'committedAt', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByCommittedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'committedAt', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByDesktopId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByDesktopIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByDesktopUserId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopUserId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByDesktopUserIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'desktopUserId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByJobId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'jobId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByJobIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'jobId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByLocalSongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localSongId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByLocalSongIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'localSongId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByOperationKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'operationKey', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByOperationKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'operationKey', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByOrigin() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'origin', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByOriginDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'origin', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByPairingId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'pairingId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByPairingIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'pairingId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByPreparedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'preparedAt', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByPreparedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'preparedAt', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByRelativePath() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'relativePath', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByRelativePathDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'relativePath', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByRevision() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'revision', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByRevisionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'revision', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByServerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByServerIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'serverId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySha256() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sha256', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySha256Desc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sha256', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySourceId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sourceId', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenBySourceIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'sourceId', Sort.desc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByState() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.asc);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QAfterSortBy>
  thenByStateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'state', Sort.desc);
    });
  }
}

extension IosTransferReceiptEntityQueryWhereDistinct
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QDistinct
        > {
  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByBytes() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bytes');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByCommittedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'committedAt');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByDesktopId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'desktopId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByDesktopUserId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(
        r'desktopUserId',
        caseSensitive: caseSensitive,
      );
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByJobId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'jobId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByLocalSongId() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'localSongId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByOperationKey({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'operationKey', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByOrigin({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'origin', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByPairingId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'pairingId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByPreparedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'preparedAt');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByRelativePath({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'relativePath', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByRevision() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'revision');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'schemaVersion');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByServerId() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'serverId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctBySha256({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sha256', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctBySourceId({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'sourceId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<IosTransferReceiptEntity, IosTransferReceiptEntity, QDistinct>
  distinctByState({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'state', caseSensitive: caseSensitive);
    });
  }
}

extension IosTransferReceiptEntityQueryProperty
    on
        QueryBuilder<
          IosTransferReceiptEntity,
          IosTransferReceiptEntity,
          QQueryProperty
        > {
  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations>
  bytesProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bytes');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, DateTime?, QQueryOperations>
  committedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'committedAt');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  desktopIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'desktopId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String?, QQueryOperations>
  desktopUserIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'desktopUserId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  jobIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'jobId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations>
  localSongIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'localSongId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  operationKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'operationKey');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  originProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'origin');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  pairingIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'pairingId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, DateTime, QQueryOperations>
  preparedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'preparedAt');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  relativePathProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'relativePath');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations>
  revisionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'revision');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations>
  schemaVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'schemaVersion');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, int, QQueryOperations>
  serverIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'serverId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  sha256Property() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sha256');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  sourceIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'sourceId');
    });
  }

  QueryBuilder<IosTransferReceiptEntity, String, QQueryOperations>
  stateProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'state');
    });
  }
}
