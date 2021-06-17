import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:dartx/dartx.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart';
import 'package:playbook/playbook_annotations.dart';
import 'package:source_gen/source_gen.dart'
    show LibraryReader, TypeChecker, defaultFileHeader;

import 'constant_reader_utils.dart';

class PlaybookBuilder implements Builder {
  static const _outputName = 'generated_playbook.dart';
  static const _playbookUrl = 'package:playbook/playbook.dart';

  @override
  Map<String, List<String>> get buildExtensions {
    return const {
      r'$lib$': [_outputName],
    };
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final storyAssets = buildStep.findAssets(Glob('lib/**/*.story.dart'));
    final storyFunctions = <Method>[];

    await for (final input in storyAssets) {
      final storyLibrary = await buildStep.resolver.libraryFor(input);
      final storyLibraryReader = LibraryReader(storyLibrary);

      final scenarioCodes = _createScenarioCodes(storyLibraryReader);
      if (scenarioCodes.isEmpty) continue;

      final storyTitle = _findStoryTitle(storyLibraryReader);
      storyFunctions.add(_createStoryFunction(
        storyTitle,
        scenarioCodes,
        storyLibraryReader,
      ));
    }

    final storiesLibrary = Library(
      (b) => b
        ..body.addAll([
          _createPlaybookGetter(),
          _createStoriesGetter(storyFunctions),
          ...storyFunctions,
        ]),
    );
    final emitter = DartEmitter(
      allocator: Allocator.simplePrefixing(),
      orderDirectives: true,
      useNullSafetySyntax: true,
    );
    final content = DartFormatter().format(
      '''
$defaultFileHeader

${storiesLibrary.accept(emitter)}
''',
    );
    await buildStep.writeAsString(_output(buildStep), content);
  }

  List<Code> _createScenarioCodes(LibraryReader storyLibraryReader) {
    final uri = storyLibraryReader.element.librarySource.uri.toString();

    final generatedScenarioCodes = storyLibraryReader
        .annotatedWith(TypeChecker.fromRuntime(GenerateScenario))
        .where((e) {
      if (e.element is! ClassElement) return false;
      final classElement = e.element as ClassElement;
      return classElement.isPublic &&
          classElement.unnamedConstructor?.isDefaultConstructor == true &&
          classElement.allSupertypes.any(
              (s) => s.getDisplayString(withNullability: true) == 'Widget');
    }).map((e) {
      final annotation = e.annotation;
      final title = annotation.read('title');
      final titleParam = title.isString
          ? title.stringValue
          : e.element.displayName.removePrefix('\$').replaceAll('_', ' ');
      final scaleParam = annotation.read('scale').doubleValue;
      return Code.scope((a) => '''
${a(refer('Scenario', _playbookUrl))}(
  '$titleParam',
  layout: ${constantReaderToSource(annotation.read('layout'), a)},
  scale: $scaleParam,
  child: ${a(refer(e.element.displayName, uri))}(),
)''');
    });

    final scenarioCodes = storyLibraryReader.element.topLevelElements
        .whereType<FunctionElement>()
        .where((e) => e.isPublic && e.parameters.isEmpty)
        .flatMap<Code>(
      (e) {
        final returnTypeString =
            e.returnType.getDisplayString(withNullability: true);
        final scenarioRefer = refer(e.displayName, uri);
        if (returnTypeString == 'Scenario') {
          return [scenarioRefer([]).code];
        } else if (returnTypeString == 'List<Scenario>') {
          return [Code.scope((a) => '...${a(scenarioRefer)}()')];
        } else {
          return [];
        }
      },
    );
    return <Code>[...generatedScenarioCodes, ...scenarioCodes];
  }

  Method _createStoryFunction(
    String storyTitle,
    List<Code> scenarioCodes,
    LibraryReader storyLibraryReader,
  ) {
    final storyRefer = refer('Story', _playbookUrl);
    final name = storyLibraryReader.element.source.uri.pathSegments
        .drop(1)
        .map((e) => '\$${e.split('.').first}')
        .join();
    final storyFunction = Method((b) => b
      ..returns = storyRefer
      ..name = '_$name\$Story'
      ..body = storyRefer.call([
        literalString(storyTitle)
      ], {
        'scenarios': literalList(scenarioCodes),
      }).code);
    return storyFunction;
  }

  Method _createStoriesGetter(List<Method> storyMethods) {
    final bodyExpression =
        literalList(storyMethods.map((e) => refer('${e.name}()')));
    return Method((b) => b
      ..name = 'stories'
      ..type = MethodType.getter
      ..returns = TypeReference(
        (b) => b
          ..symbol = 'List'
          ..types.add(refer('Story', _playbookUrl).type),
      )
      ..body = bodyExpression.code);
  }

  Method _createPlaybookGetter() {
    final playbookRefer = refer('Playbook', _playbookUrl);
    return Method(
      (b) => b
        ..name = 'playbook'
        ..type = MethodType.getter
        ..returns = playbookRefer
        ..body = playbookRefer.call([], {
          'stories': refer('stories'),
        }).code,
    );
  }

  String _findStoryTitle(LibraryReader storyLibraryReader) {
    final storyTitle = storyLibraryReader.element.topLevelElements
        .whereType<VariableElement>()
        .firstOrNullWhere((e) => e.name == 'storyTitle')
        ?.computeConstantValue()
        ?.toStringValue();

    final librarySource = storyLibraryReader.element.source;
    assert(storyTitle != null,
        'Library ${librarySource.source.fullName} need define the story title.');
    return storyTitle!;
  }

  AssetId _output(BuildStep buildStep) {
    return AssetId(
      buildStep.inputId.package,
      join('lib', _outputName),
    );
  }
}
