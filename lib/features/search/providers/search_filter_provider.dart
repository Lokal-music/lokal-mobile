import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_category.dart';

enum SearchScope { all, library, online }

bool supportsOnlineCategory(SearchCategory? category) =>
    category == null ||
    category == SearchCategory.songs ||
    category == SearchCategory.artists ||
    category == SearchCategory.albums;

class SearchScopeNotifier extends Notifier<SearchScope> {
  @override
  SearchScope build() => SearchScope.all;
  void select(SearchScope scope) {
    if (scope == SearchScope.online &&
        !supportsOnlineCategory(ref.read(searchFilterProvider).singleOrNull)) {
      ref.read(searchFilterProvider.notifier).select(null);
    }
    state = scope;
  }
}

final searchScopeProvider = NotifierProvider<SearchScopeNotifier, SearchScope>(
  SearchScopeNotifier.new,
);

/// One result type, or All. The old exclusion-mask preferences are deliberately
/// not migrated: seven selected chips did not mean seven explicit choices.
class SearchFilterNotifier extends Notifier<Set<SearchCategory>> {
  static const _key = 'search_selected_category_v2';
  bool _changed = false;
  Future<void> _saving = Future<void>.value();
  @override
  Set<SearchCategory> build() {
    Future.microtask(_load);
    return SearchCategory.values.toSet();
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
    state = category == null ? SearchCategory.values.toSet() : {category};
    if (!supportsOnlineCategory(category) &&
        ref.read(searchScopeProvider) == SearchScope.online) {
      ref.read(searchScopeProvider.notifier).select(SearchScope.library);
    }
    _saving = _saving
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, category?.storageKey ?? 'all');
        })
        .catchError((Object _) {});
  }

  void toggle(SearchCategory category) => select(category);
  void toggleAll() => select(null);
  bool get isAllEnabled => state.length == SearchCategory.values.length;
}

final searchFilterProvider =
    NotifierProvider<SearchFilterNotifier, Set<SearchCategory>>(
      SearchFilterNotifier.new,
    );
final searchAllEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(searchFilterProvider).length == SearchCategory.values.length,
);
