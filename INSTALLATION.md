# VK HLS Parser - Инструкция по установке

## 📦 Содержимое архива

```
vk_parser_update/
├── python_scripts/vk_parser/
│   ├── hls_parser.py              # Парсер M3U8 и дешифровщик AES-128
│   ├── vk_metadata.py             # Экстрактор метаданных
│   ├── main.py                    # Главный мост Flask <-> Python
│   └── requirements.txt            # Python зависимости
│
├── lib/services/
│   ├── vk_hls_service.dart        # Dart сервис HLS операций
│   └── vk_service_updated.dart    # Обновленный VK сервис
│
├── android/app/src/main/kotlin/com/example/rydmusic/
│   └── VKHLSBridge.kt             # Kotlin Method Channel интеграция
│
├── docs/
│   ├── README_UPDATES.md          # Обзор обновлений
│   ├── VK_HLS_INTEGRATION_GUIDE.md # Подробный гайд
│   └── INSTALLATION.md            # Этот файл
│
└── INSTALLATION.md
```

## 🎯 Пошаговая установка

### Шаг 1: Установка Python зависимостей

```bash
cd python_scripts/vk_parser
pip install -r requirements.txt
```

Требуется:
- Python 3.8+
- pip (package manager)

Установит:
- `requests` - для HTTP запросов
- `pycryptodome` - для AES-128 дешифровки

### Шаг 2: Копирование Python скриптов в проект

```bash
# Из корневой директории архива
cp -r python_scripts/vk_parser /path/to/your/project/

# Или вручную в pubspec.yaml добавить как assets:
flutter:
  assets:
    - python_scripts/vk_parser/hls_parser.py
    - python_scripts/vk_parser/vk_metadata.py
    - python_scripts/vk_parser/main.py
    - python_scripts/vk_parser/requirements.txt
```

### Шаг 3: Интеграция Dart сервисов

```bash
# Копировать оба файла в lib/services/
cp lib/services/vk_hls_service.dart /path/to/your/project/lib/services/
cp lib/services/vk_service_updated.dart /path/to/your/project/lib/services/
```

**Или заменить существующий VK сервис:**

```dart
// Старый импорт:
import 'services/vk_service.dart';

// Новый импорт (используйте это):
import 'services/vk_service_updated.dart';

// Использование остается прежним
final vkService = VkService();
```

### Шаг 4: Интеграция Android (Kotlin)

#### 4a. Копировать Kotlin код

```bash
cp android/app/src/main/kotlin/com/example/rydmusic/VKHLSBridge.kt \
   /path/to/your/project/android/app/src/main/kotlin/com/example/rydmusic/
```

#### 4b. Обновить MainActivity

Открыть `android/app/src/main/kotlin/com/example/rydmusic/MainActivity.kt`:

```kotlin
package com.example.rydmusic

import android.os.Bundle
import com.example.rydmusic.VKHLSBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    private lateinit var vkHLSBridge: VKHLSBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Инициализируем VK HLS мост
        vkHLSBridge = VKHLSBridge(this)
        vkHLSBridge.setupChannel(flutterEngine)
    }

    override fun onDestroy() {
        vkHLSBridge.cleanup()
        super.onDestroy()
    }
}
```

#### 4c. Обновить build.gradle

Открыть `android/app/build.gradle`:

```gradle
dependencies {
    // ... существующие зависимости
    
    // Добавить для корутин (если еще нет)
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.6.4"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.6.4"
}
```

### Шаг 5: Обновить pubspec.yaml

Добавить assets:

```yaml
flutter:
  uses-material-design: true
  
  # Добавить эти строки
  assets:
    - python_scripts/vk_parser/hls_parser.py
    - python_scripts/vk_parser/vk_metadata.py
    - python_scripts/vk_parser/main.py
    - python_scripts/vk_parser/requirements.txt
```

### Шаг 6: Очистка и пересборка

```bash
# Очистить Flutter кэш
flutter clean

# Получить зависимости
flutter pub get

# Пересобрать проект
flutter build apk  # или другой вариант
```

## 🔍 Проверка установки

### Проверка Python скриптов

```bash
cd python_scripts/vk_parser

# Тест парсинга (с реальным URL):
python3 main.py parse "https://vk.com/audio123456.m3u8"

# Вывод должен быть JSON с информацией о плейлисте
```

### Проверка Dart интеграции

```dart
import 'services/vk_hls_service.dart';

void testVKHLS() async {
  const testUrl = 'https://example.com/audio.m3u8';
  
  // Тест парсинга
  final info = await VKHLSService.parseM3U8(testUrl);
  if (info != null) {
    print('✓ HLS парсинг работает');
    print('  Сегментов: ${info.segmentsCount}');
  } else {
    print('✗ Ошибка парсинга');
  }
}
```

## ⚙️ Конфигурация

### Timeout для загрузки

По умолчанию timeout = 10 секунд. Можно изменить в `hls_parser.py`:

```python
response = self.session.get(m3u8_url, timeout=30)  # 30 секунд
```

### User-Agent для requests

Изменить в `hls_parser.py`:

```python
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Custom UA)'
}
```

## 🐛 Troubleshooting

### Ошибка: "No module named 'Crypto'"

```bash
pip install pycryptodome
```

### Ошибка: "Method Channel not found"

Убедитесь, что:
1. `VKHLSBridge` импортирована в MainActivity
2. `setupChannel()` вызывается в `configureFlutterEngine()`
3. Имена каналов совпадают в Dart и Kotlin

### Ошибка: "Python process timeout"

Увеличьте timeout в `VKHLSBridge.kt`:

```kotlin
val process = ProcessBuilder(command).start()
val timeout = 60  // 60 секунд вместо 10
```

### Ошибка: "File not found"

Убедитесь, что Python скрипты добавлены в `pubspec.yaml` как assets и файлы скопированы в правильные места.

## 📊 Проверка структуры

Финальная структура проекта должна выглядеть так:

```
your_project/
├── lib/
│   ├── services/
│   │   ├── vk_hls_service.dart       ✓ ДОБАВЛЕНО
│   │   ├── vk_service_updated.dart   ✓ ДОБАВЛЕНО/ЗАМЕНЕНО
│   │   └── ... остальные сервисы
│   └── ... остальной код
│
├── android/
│   └── app/src/main/kotlin/com/example/rydmusic/
│       ├── MainActivity.kt            ✓ ОБНОВЛЕНО
│       ├── VKHLSBridge.kt            ✓ ДОБАВЛЕНО
│       └── ...
│
├── python_scripts/
│   └── vk_parser/                    ✓ ДОБАВЛЕНО
│       ├── hls_parser.py
│       ├── vk_metadata.py
│       ├── main.py
│       └── requirements.txt
│
├── pubspec.yaml                       ✓ ОБНОВЛЕНО
└── ...
```

## 📚 Документация

### Основные файлы документации

1. **docs/README_UPDATES.md** - Обзор всех изменений
2. **docs/VK_HLS_INTEGRATION_GUIDE.md** - Подробный гайд интеграции
3. **docs/INSTALLATION.md** - Этот файл

### Примеры использования

```dart
// Пример 1: Парсинг M3U8
final info = await VKHLSService.parseM3U8(m3u8Url);

// Пример 2: Загрузка сегментов
final audioData = await VKHLSService.downloadAndDecryptSegments(m3u8Url);

// Пример 3: Получение метаданных
final metadata = await VKHLSService.getTrackMetadata(m3u8Url);

// Пример 4: Полная интеграция
final vkService = VkService();
final tracks = await vkService.search('query');
final resolvedTrack = await vkService.resolveStreamUrl(tracks.first);
```

## ✅ Чеклист установки

- [ ] Python зависимости установлены (`pip install -r requirements.txt`)
- [ ] Python скрипты скопированы в `python_scripts/vk_parser/`
- [ ] Dart сервисы скопированы в `lib/services/`
- [ ] Kotlin код скопирован в правильную директорию
- [ ] MainActivity обновлена с VKHLSBridge
- [ ] build.gradle обновлен с корутинами
- [ ] pubspec.yaml обновлен с assets
- [ ] `flutter clean && flutter pub get` выполнены
- [ ] Проект пересобран
- [ ] Python скрипты тестированы командной строкой
- [ ] Dart сервис тестирован в приложении

## 🎯 Следующие шаги

1. Протестировать с реальным M3U8 URL из VK
2. Добавить кэширование дешифрованных треков
3. Реализовать iOS поддержку (если нужна)
4. Добавить логирование и мониторинг
5. Оптимизировать для больших файлов (потоковая обработка)

## 💡 Советы

- Используйте realpython.com для изучения Crypto в Python
- Проверьте M3U8 вручную с помощью `curl` для отладки
- Добавьте детальное логирование для troubleshooting
- Тестируйте с небольшими треками сначала
- Используйте `python3 main.py` напрямую для тестирования скриптов

## 📝 Лицензия

Этот код предназначен для портфолио и образовательных целей.

---

**Версия**: 1.1.0
**Дата**: 2026-09-18
**Статус**: Ready for Integration
