import 'dart:convert';
import 'package:http/http.dart' as http;

// --- CHAT MODELS ---
// Identifiers for SharedPreferences and logic
class ChatModels {
  static const String gemini = 'gemini-2.0-flash';
  static const String gpt4_1_mini = 'openai'; // Default Pollinations model
  static const String gpt4_1 = 'openai-large';
  static const String openai_o3 = 'openai-reasoning';
  static const String deepseek_r1 = 'deepseek-reasoning';
  static const String searchGpt = 'searchgpt';
}

// --- API CONFIGURATION ---
class ApiConfig {
  // Gemini
  static const String geminiApiKey = 'AIzaSyBUiSSswKvLvEK7rydCCRPF50eIDI_KOGc';
  static const String geminiChatModel = ChatModels.gemini;
  static const String presentationModelName = 'gemini-2.5-flash';

  // OpenRouter ("Thinking Mode")
  static const String openRouterApiKey = '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';
  static const String openRouterChatUrl = 'https://openrouter.ai/api/v1/chat/completions';
  static const String openRouterModel = 'rekaai/reka-flash-3:free';

  // Brave Search
  static const String braveSearchApiKey = 'BSAGvn27KGywhzSPWjem5a_r41ZYaB2';
  static const String braveSearchUrl = 'https://api.search.brave.com/res/v1/web/search';

  // Pollinations
  static String getPollinationsChatUrl(String prompt, String modelName) {
    final encodedPrompt = Uri.encodeComponent(prompt);
    var url = 'https://text.pollinations.ai/$encodedPrompt';

    // Append the model parameter if it's not the default Pollinations model.
    if (modelName != ChatModels.gpt4_1_mini) {
      url += '?model=$modelName';
    }
    return url;
  }
}

// --- IMAGE API ---
class ImageApi {
  static const String _baseUrl = 'https://image.pollinations.ai';

  static Future<List<String>> fetchModels() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/models'));
      if (response.statusCode == 200) {
        final List<dynamic> modelsJson = jsonDecode(response.body);
        final models = modelsJson.cast<String>();
        if (models.contains('flux')) {
          models.remove('flux');
          models.insert(0, 'flux');
        }
        return models;
      } else {
        return ['flux', 'sdxl', 'dall-e-3']; // Fallback
      }
    } catch (e) {
      print("Error fetching image models: $e");
      return ['flux', 'sdxl', 'dall-e-3']; // Fallback
    }
  }

  static String getImageUrl(String prompt, {String? model}) {
    final encodedPrompt = Uri.encodeComponent(prompt);
    var url = '$_baseUrl/prompt/$encodedPrompt?nologo=true&width=512&height=512';
    if (model != null && model.isNotEmpty && model != 'flux') {
      url += '&model=${Uri.encodeComponent(model)}';
    }
    return url;
  }
}