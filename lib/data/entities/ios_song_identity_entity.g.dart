// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ios_song_identity_entity.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetIosSongIdentityEntityCollection on Isar {
  IsarCollection<IosSongIdentityEntity> get iosSongIdentityEntitys =>
      this.collection();
}

const IosSongIdentityEntitySchema = CollectionSchema(
  name: r'IosSongIdentityEntity',
  id: 8556822458895873866,
  properties: {
    r'lastAllocated': PropertySchema(
      id: 0,
      name: r'lastAllocated',
      type: IsarType.long,
    ),
    r'schemaVersion': PropertySchema(
      id: 1,
      name: r'schemaVersion',
      type: IsarType.long,
    ),
  },

  estimateSize: _iosSongIdentityEntityEstimateSize,
  serialize: _iosSongIdentityEntitySerialize,
  deserialize: _iosSongIdentityEntityDeserialize,
  deserializeProp: _iosSongIdentityEntityDeserializeProp,
  idName: r'id',
  indexes: {},
  links: {},
  embeddedSchemas: {},

  getId: _iosSongIdentityEntityGetId,
  getLinks: _iosSongIdentityEntityGetLinks,
  attach: _iosSongIdentityEntityAttach,
  version: '3.3.2',
);

int _iosSongIdentityEntityEstimateSize(
  IosSongIdentityEntity object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  return bytesCount;
}

void _iosSongIdentityEntitySerialize(
  IosSongIdentityEntity object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeLong(offsets[0], object.lastAllocated);
  writer.writeLong(offsets[1], object.schemaVersion);
}

IosSongIdentityEntity _iosSongIdentityEntityDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = IosSongIdentityEntity();
  object.id = id;
  object.lastAllocated = reader.readLong(offsets[0]);
  object.schemaVersion = reader.readLong(offsets[1]);
  return object;
}

P _iosSongIdentityEntityDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readLong(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _iosSongIdentityEntityGetId(IosSongIdentityEntity object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _iosSongIdentityEntityGetLinks(
  IosSongIdentityEntity object,
) {
  return [];
}

void _iosSongIdentityEntityAttach(
  IsarCollection<dynamic> col,
  Id id,
  IosSongIdentityEntity object,
) {
  object.id = id;
}

extension IosSongIdentityEntityQueryWhereSort
    on QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QWhere> {
  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhere>
  anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension IosSongIdentityEntityQueryWhere
    on
        QueryBuilder<
          IosSongIdentityEntity,
          IosSongIdentityEntity,
          QWhereClause
        > {
  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhereClause>
  idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhereClause>
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

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhereClause>
  idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhereClause>
  idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterWhereClause>
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
}

extension IosSongIdentityEntityQueryFilter
    on
        QueryBuilder<
          IosSongIdentityEntity,
          IosSongIdentityEntity,
          QFilterCondition
        > {
  QueryBuilder<
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
    QAfterFilterCondition
  >
  lastAllocatedEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'lastAllocated', value: value),
      );
    });
  }

  QueryBuilder<
    IosSongIdentityEntity,
    IosSongIdentityEntity,
    QAfterFilterCondition
  >
  lastAllocatedGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'lastAllocated',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosSongIdentityEntity,
    IosSongIdentityEntity,
    QAfterFilterCondition
  >
  lastAllocatedLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'lastAllocated',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<
    IosSongIdentityEntity,
    IosSongIdentityEntity,
    QAfterFilterCondition
  >
  lastAllocatedBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'lastAllocated',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
    IosSongIdentityEntity,
    IosSongIdentityEntity,
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
}

extension IosSongIdentityEntityQueryObject
    on
        QueryBuilder<
          IosSongIdentityEntity,
          IosSongIdentityEntity,
          QFilterCondition
        > {}

extension IosSongIdentityEntityQueryLinks
    on
        QueryBuilder<
          IosSongIdentityEntity,
          IosSongIdentityEntity,
          QFilterCondition
        > {}

extension IosSongIdentityEntityQuerySortBy
    on QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QSortBy> {
  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  sortByLastAllocated() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAllocated', Sort.asc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  sortByLastAllocatedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAllocated', Sort.desc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  sortBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  sortBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }
}

extension IosSongIdentityEntityQuerySortThenBy
    on QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QSortThenBy> {
  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenByLastAllocated() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAllocated', Sort.asc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenByLastAllocatedDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastAllocated', Sort.desc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QAfterSortBy>
  thenBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }
}

extension IosSongIdentityEntityQueryWhereDistinct
    on QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QDistinct> {
  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QDistinct>
  distinctByLastAllocated() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastAllocated');
    });
  }

  QueryBuilder<IosSongIdentityEntity, IosSongIdentityEntity, QDistinct>
  distinctBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'schemaVersion');
    });
  }
}

extension IosSongIdentityEntityQueryProperty
    on
        QueryBuilder<
          IosSongIdentityEntity,
          IosSongIdentityEntity,
          QQueryProperty
        > {
  QueryBuilder<IosSongIdentityEntity, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<IosSongIdentityEntity, int, QQueryOperations>
  lastAllocatedProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastAllocated');
    });
  }

  QueryBuilder<IosSongIdentityEntity, int, QQueryOperations>
  schemaVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'schemaVersion');
    });
  }
}
