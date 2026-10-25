import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_category.dart';

enum SearchScope { library, online }

bool supportsOnlineCategory(SearchCategory? category) =>
    category == SearchCategory.songs ||
    category == SearchCategory.artists ||
    category == SearchCategory.albums;

class SearchScopeNotifier extends Notifier<SearchScope> {
  @override
  SearchScope build() => SearchScope.library;
  void select(SearchScope scope) {
    if (scope == SearchScope.online &&
        !supportsOnlineCategory(ref.read(searchFilterProvider).singleOrNull)) {
      ref.read(searchFilterProvider.notifier).select(SearchCategory.songs);
    }
    state = scope;
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
      if (category != null &&
          (supportsOnlineCategory(category) ||
              ref.read(searchScopeProvider) != SearchScope.online))
        state = {category};
    } catch (_) {
      /* Search remains usable if preference storage fails. */
    }
  }

  void select(SearchCategory? category) {
    _changed = true;
    state = {category ?? SearchCategory.songs};
    if (!supportsOnlineCategory(category) &&
        ref.read(searchScopeProvider) == SearchScope.online) {
      ref.read(searchScopeProvider.notifier).select(SearchScope.library);
    }
    _saving = _saving
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, (category ?? SearchCategory.songs).storageKey);
        })
        .catchError((Object _) {});
  }

  void toggle(SearchCategory category) => select(category);
}

final searchFilterProvider =
    NotifierProvider<SearchFilterNotifier, Set<SearchCategory>>(
      SearchFilterNotifier.new,
    );
