import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_translate/core/config/app_config.dart';
import 'package:sync_translate/core/translate/translator.dart';
import 'package:sync_translate/core/translate/translator_llm.dart';

void main() {
  test('source language, context and terminology reach the selected model', () async {
    final requests = <Map<String, dynamic>>[];
    final translator = LlmTranslator(client: MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({
        'choices': [
          {'message': {'content': '自然译文'}, 'finish_reason': 'stop'},
        ],
      }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(translator.dispose);
    await translator.init(TranslatorConfig(
      apiKey: 'test', sourceLang: 'ja', model: 'main', fastModel: 'fast',
      translationGuide: 'render → 渲染',
    ));
    expect(await translator.translate('原文', context: '前文 → 译文'), '自然译文');
    await translator.translate('原文', sourceLang: 'en', provisional: true);
    final messages = requests.first['messages'] as List<dynamic>;
    expect(messages[0]['content'], contains('"ja"'));
    expect(messages[0]['content'], contains('render → 渲染'));
    expect(jsonDecode(messages[1]['content'] as String), {
      'previous_context': '前文 → 译文', 'current_subtitle': '原文',
    });
    expect(requests.first['model'], 'main');
    expect(requests.last['model'], 'fast');
    expect(requests.last['messages'][0]['content'], contains('"en"'));
  });

  test('empty and truncated translations fail visibly', () async {
    for (final response in [
      {'message': {'content': ' '}, 'finish_reason': 'stop'},
      {'message': {'content': '半句'}, 'finish_reason': 'length'},
    ]) {
      final translator = LlmTranslator(client: MockClient((_) async =>
          http.Response(jsonEncode({'choices': [response]}), 200)));
      addTearDown(translator.dispose);
      await translator.init(TranslatorConfig(apiKey: 'test'));
      await expectLater(translator.translate('hello'), throwsA(isA<TranslateException>()));
    }
  });

  test('translation guide survives save/load and old settings remain valid', () {
    expect(TranslatorConfig.fromJson({}).translationGuide, '');
    final config = TranslatorConfig(translationGuide: '人名：Alice → 爱丽丝');
    expect(TranslatorConfig.fromJson(config.toJson()).translationGuide,
        config.translationGuide);
  });
}
