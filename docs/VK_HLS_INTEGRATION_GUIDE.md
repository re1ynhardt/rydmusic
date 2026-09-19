# VK HLS Parser & AES-128 Decryption Integration Guide

## Обзор

Это полноценное решение для парсинга, загрузки и дешифровки аудиотреков из ВКонтакте через HLS потоки с поддержкой AES-128-CBC.

### Компоненты

1. **Python Scripts** - Низкоуровневые скрипты для работы с HLS и AES-128
   - `hls_parser.py` - Парсер M3U8 манифестов и дешифровщик сегментов
   - `vk_metadata.py` - Экстрактор метаданных трека
   - `main.py` - Главный мост для Flutter интеграции

2. **Dart Services** - Сервисы Flutter для взаимодействия с Python
   - `vk_hls_service.dart` - HLS парсинг и дешифровка
   - `vk_service_updated.dart` - Обновленный VK сервис

3. **Kotlin Bridge** - Android нативный код для запуска Python
   - `VKHLSBridge.kt` - Method Channel интеграция

## Архитектура

```
Flutter (Dart)
    ↓
Method Channel (Kotlin)
    ↓
Python Process
    ├── hls_parser.py (HLS + AES-128)
    ├── vk_metadata.py (Track Info)
    └── main.py (Bridge)
```

## Установка

### 1. Python Dependencies

```bash
pip install -r python_scripts/vk_parser/requirements.txt
```

Требуемые пакеты:
- `requests` - HTTP запросы
- `pycryptodome` - AES-128 дешифровка

### 2. Flutter Integration

#### Обновить `pubspec.yaml`

Зависимости уже установлены, но убедитесь в наличии:

```yaml
dependencies:
  flutter:
    sdk: flutter
  # ... остальные зависимости
```

#### Добавить Python скрипты в assets

Создать `pubspec.yaml`:

```yaml
flutter:
  assets:
    - python_scripts/vk_parser/hls_parser.py
    - python_scripts/vk_parser/vk_metadata.py
    - python_scripts/vk_parser/main.py
    - python_scripts/vk_parser/requirements.txt
```

### 3. Android Setup

#### Добавить Kotlin код

Скопировать `android/app/src/main/kotlin/com/example/rydmusic/VKHLSBridge.kt`

#### Обновить MainActivity

```kotlin
import com.example.rydmusic.VKHLSBridge

class MainActivity: FlutterActivity() {
    private lateinit var vkHLSBridge: VKHLSBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        vkHLSBridge = VKHLSBridge(this)
        vkHLSBridge.setupChannel(flutterEngine)
    }

    override fun onDestroy() {
        vkHLSBridge.cleanup()
        super.onDestroy()
    }
}
```

#### Обновить build.gradle

```gradle
dependencies {
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.6.4"
}
```

### 4. iOS Setup (Optional)

Для iOS нужно использовать Python runtime через PyBridge или аналогичное решение.

## Использование

### 1. Парсинг M3U8

```dart
import 'package:rydmusic/services/vk_hls_service.dart';

final playlistInfo = await VKHLSService.parseM3U8(m3u8Url);
if (playlistInfo != null) {
  print('Segments: ${playlistInfo.segmentsCount}');
  print('Duration: ${playlistInfo.totalDuration}s');
}
```

### 2. Загрузка и дешифровка сегментов

```dart
final audioData = await VKHLSService.downloadAndDecryptSegments(
  m3u8Url,
  outputFile: '/path/to/output.mp3',
);

if (audioData != null) {
  print('Downloaded ${audioData.length} bytes');
}
```

### 3. Получение метаданных

```dart
final metadata = await VKHLSService.getTrackMetadata(m3u8Url);
if (metadata != null) {
  print('Title: ${metadata.title}');
  print('Artist: ${metadata.artist}');
  print('Cover: ${metadata.coverUrl}');
}
```

### 4. Полный процесс в VK сервисе

```dart
final track = await vkService.resolveStreamUrl(track);
// Если это HLS поток, он будет автоматически распарсен и дешифрован
```

## Детали реализации

### HLS M3U8 Парсинг

Скрипт `hls_parser.py` парсит M3U8 манифесты:

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin",IV=0x...
#EXTINF:6.0,
segment1.ts
#EXTINF:6.0,
segment2.ts
...
```

### AES-128-CBC Дешифровка

Процесс дешифровки:

1. **Загрузка ключа** из URI в манифесте
2. **Парсинг IV** (Initialization Vector) из `#EXT-X-KEY` тега
3. **Дешифровка каждого сегмента** используя AES-128-CBC
4. **Удаление PKCS7 padding** после дешифровки
5. **Объединение сегментов** в один аудиопоток

### Метаданные трека

Экстрактор `vk_metadata.py` получает:

- Название трека (Title)
- Исполнитель (Artist)
- Длительность (Duration)
- Обложку альбома (Cover URL)
- Текст песни (Lyrics) - если доступны
- Альбом, дату выпуска, жанр

## Обработка ошибок

### Fallback механизм

Если Method Channel недоступен, Dart код автоматически переходит на:

1. Прямой вызов Python скриптов через `_pythonBridge` channel
2. Использование yt-dlp (существующий механизм)

```dart
// Автоматический fallback
try {
  response = await _channel.invokeMethod('parseM3U8', {'url': m3u8Url});
} catch (e) {
  // Fallback to Python
  response = await _pythonBridge.invokeMethod('runScript', {...});
}
```

## Производительность

### Оптимизации

1. **Параллельная загрузка** - Сегменты загружаются последовательно, но это можно оптимизировать
2. **Кэширование** - Зашифрованные ключи кэшируются
3. **Потоковая дешифровка** - Сегменты дешифруются по мере загрузки

### Рекомендации

- Для больших треков (>30 минут) использовать потоковое воспроизведение
- Кэшировать дешифрованные треки локально
- Использовать `downloadAndDecryptSegments` с `outputFile` параметром для локального сохранения

## Тестирование

### Тестирование Python скриптов

```bash
# Парсинг M3U8
python3 main.py parse "https://example.com/track.m3u8"

# Загрузка и дешифровка
python3 main.py download "https://example.com/track.m3u8" --output track.mp3

# Получение метаданных
python3 main.py metadata "https://example.com/track.m3u8"
```

### Тестирование в приложении

```dart
void testVKHLS() async {
  const testUrl = 'https://example.com/audio.m3u8';
  
  // Тест парсинга
  final info = await VKHLSService.parseM3U8(testUrl);
  assert(info != null, 'M3U8 parsing failed');
  
  // Тест метаданных
  final metadata = await VKHLSService.getTrackMetadata(testUrl);
  assert(metadata != null, 'Metadata extraction failed');
  
  // Тест загрузки
  final audio = await VKHLSService.downloadAndDecryptSegments(testUrl);
  assert(audio != null && audio.isNotEmpty, 'Audio download failed');
}
```

## Troubleshooting

### "AES decryption failed"

- Проверьте, что ключ загружается правильно
- Убедитесь, что IV парсится корректно
- Проверьте, что данные сегмента не повреждены

### "Empty M3U8 response"

- Проверьте URL манифеста
- Убедитесь, что сервер возвращает правильный Content-Type
- Проверьте User-Agent в headers

### "Python process timeout"

- Увеличьте timeout в `runPythonCommand`
- Проверьте наличие Python на устройстве
- Убедитесь, что все зависимости установлены

### "Method Channel not found"

- Убедитесь, что `VKHLSBridge` инициализирован в MainActivity
- Проверьте имена каналов совпадают
- Проверьте Kotlin код в Android

## Лицензирование

Этот код является частью портфолио проекта и предназначен только для демонстрационных целей.

## Будущие улучшения

1. ✅ Поддержка HLS парсинга
2. ✅ AES-128-CBC дешифровка
3. ✅ Получение метаданных
4. 🔄 Потоковое воспроизведение без полной загрузки
5. 🔄 Кэширование в локальной БД
6. 🔄 Поддержка других методов шифрования (AES-256, etc.)
7. 🔄 iOS реализация
8. 🔄 Поддержка DASH потоков

## Контакты и поддержка

Для вопросов и проблем см. документацию VK_PARSER_SETUP.md
