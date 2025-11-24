import '../../core/models/archive_models.dart';
import 'archive_search_models.dart';

/// Builds and parses archive search queries plus fuzzy variants
class ArchiveSearchQueryBuilder {
  ParsedSearchQuery parse(String query) {
    final tokens = <String>[];
    final phrases = <String>[];
    final excludedTerms = <String>[];
    final operators = <SearchOperator>[];

    final words = query
        .toLowerCase()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();

    for (final word in words) {
      if (word.startsWith('-')) {
        excludedTerms.add(word.substring(1));
      } else if (word.startsWith('"') && word.endsWith('"')) {
        phrases.add(word.substring(1, word.length - 1));
      } else {
        tokens.add(word);
      }
    }

    return ParsedSearchQuery(
      originalQuery: query,
      tokens: tokens,
      phrases: phrases,
      excludedTerms: excludedTerms,
      operators: operators,
    );
  }

  String normalize(ParsedSearchQuery query) {
    return query.tokens.join(' ');
  }

  SearchStrategy determineStrategy(
    ParsedSearchQuery query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
  ) {
    if (query.phrases.isNotEmpty) return SearchStrategy.phrase;
    if (options?.fuzzySearch == true) return SearchStrategy.fuzzy;
    if (filter?.dateRange != null) return SearchStrategy.temporal;
    if (query.tokens.length > 3) return SearchStrategy.complex;
    return SearchStrategy.simple;
  }

  List<String> generateFuzzyTerms(String query, double threshold) {
    // Simplified edit distance placeholder to preserve prior behavior
    return _generateEditDistanceVariations(query, 1).take(10).toList();
  }

  String buildFuzzyQuery(String original, List<String> fuzzyTerms) {
    final queryBuilder = StringBuffer(original);

    for (final term in fuzzyTerms.take(3)) {
      queryBuilder.write(' OR $term');
    }

    return queryBuilder.toString();
  }

  List<String> extractCommonTerms(ArchiveSearchResult result) {
    final termFrequency = <String, int>{};

    for (final message in result.messages) {
      final words = message.content.toLowerCase().split(' ');
      for (final word in words) {
        if (word.length > 3) {
          termFrequency[word] = (termFrequency[word] ?? 0) + 1;
        }
      }
    }

    final sortedTerms = termFrequency.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedTerms.map((e) => e.key).take(5).toList();
  }

  List<String> _generateEditDistanceVariations(String word, int maxDistance) {
    // Placeholder for edit-distance-based term generation; maintains previous behavior
    return [word];
  }
}
