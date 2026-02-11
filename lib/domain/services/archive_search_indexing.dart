import 'package:logging/logging.dart';
import '../interfaces/i_archive_repository.dart';
import '../../domain/entities/archived_chat.dart';

/// Manages archive search indexes and content tokenization
class ArchiveSearchIndexing {
  final _logger = Logger('ArchiveSearchIndexing');
  final IArchiveRepository _archiveRepository;

  final Map<String, Set<String>> _termIndex = {};
  final Map<String, Set<String>> _fuzzyIndex = {};

  ArchiveSearchIndexing({required IArchiveRepository archiveRepository})
    : _archiveRepository = archiveRepository;

  Map<String, Set<String>> get termIndex => _termIndex;
  Map<String, Set<String>> get fuzzyIndex => _fuzzyIndex;

  Future<void> rebuildIndexes() async {
    try {
      _termIndex.clear();
      _fuzzyIndex.clear();

      final summaries = await _archiveRepository.getArchivedChats();
      for (final summary in summaries) {
        final archive = await _archiveRepository.getArchivedChat(summary.id);
        if (archive != null) {
          _indexArchiveContent(archive);
        }
      }

      _logger.info('Rebuilt search indexes for ${summaries.length} archives');
    } catch (e) {
      _logger.severe('Failed to rebuild search indexes: $e');
    }
  }

  void clearIndexes() {
    _termIndex.clear();
    _fuzzyIndex.clear();
  }

  List<TermFrequency> findTermsContaining(String partial, int limit) {
    final results = <TermFrequency>[];

    for (final term in _termIndex.keys) {
      if (term.contains(partial) && results.length < limit) {
        final frequency = _termIndex[term]?.length ?? 0;
        results.add(TermFrequency(term, frequency));
      }
    }

    return results;
  }

  void _indexArchiveContent(ArchivedChat archive) {
    final contactTerms = _tokenizeText(archive.contactName);
    for (final term in contactTerms) {
      _termIndex.putIfAbsent(term, () => {}).add(archive.id.value);
    }

    for (final message in archive.messages) {
      final messageTerms = _tokenizeText(message.searchableText);
      for (final term in messageTerms) {
        _termIndex.putIfAbsent(term, () => {}).add(archive.id.value);
      }
    }
  }

  Set<String> _tokenizeText(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 2)
        .toSet();
  }
}

class TermFrequency {
  final String term;
  final int frequency;

  TermFrequency(this.term, this.frequency);
}
