import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_category.dart';

enum SearchScope { all, library, online }

const visibleSearchCategories = [
  SearchCategory.songs, SearchCategory.artists,
  SearchCategory.albums, SearchCategory.lyrics,
];

bool supportsOnlineCategory(SearchCategory? category) =>
    category != null && visibleSearchCategories.contains(category);

class SearchScopeNotifier extends Notifier<SearchScope> {
  static const _key = 'search_selected_scope_v1';
  bool _changed = false;
  Future<void> _saving = Future<void>.value();

  @override
  SearchScope build() {
    Future.microtask(_load);
    return SearchScope.library;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _changed) return;
      final saved = prefs.getString(_key);
      final scope = SearchScope.values.where((s) => s.name == saved).firstOrNull;
      if (scope != null) state = scope;
    } catch (_) {
      // Keep Search usable when saved preferences are unavailable.
    }
  }

  void select(SearchScope scope) {
    _changed = true;
    if (scope == SearchScope.online &&
        !supportsOnlineCategory(ref.read(searchFilterProvider).singleOrNull)) {
      ref.read(searchFilterProvider.notifier).select(SearchCategory.songs);
    }
    state = scope;
    _saving = _saving.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, scope.name);
    }).catchError((Object _) {});
  }
}

final searchScopeProvider = NotifierProvider<SearchScopeNotifier, SearchScope>(
  SearchScopeNotifier.new,
);

/// Exactly one result type is always selected. Old 'all' filters migrate to Songs.
class SearchFilterNotifier extends Notifier<Set<SearchCategory>> {
  static const _key = 'search_selected_category_v2';
  bool _changed = false;
  Future<void> _saving = Future<void>.value();
  @override
  Set<SearchCategory> build() {
    Future.microtask(_load);
    return {SearchCategory.songs};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _changed) return;
      final stored = prefs.getString(_key);
      final category = stored == null
          ? null
          : SearchCategoryX.fromStorageKey(stored);
      if (supportsOnlineCategory(category)) state = {category!};
    } catch (_) {
      /* Search remains usable if preference storage fails. */
    }
  }

  void select(SearchCategory? category) {
    _changed = true;
    final selected = supportsOnlineCategory(category)
        ? category! : SearchCategory.songs;
    state = {selected};
    _saving = _saving
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, selected.storageKey);
        })
        .catchError((Object _) {});
  }

  void toggle(SearchCategory category) => select(category);
}

final searchFilterProvider =
    NotifierProvider<SearchFilterNotifier, Set<SearchCategory>>(
      SearchFilterNotifier.new,
    );
