import 'dart:async';
import 'dart:convert';
import 'package:aham/web_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'main.dart';
import 'presentation_generator.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  final List<ChatMessage>? initialMessages;
  final String? initialMessage;
  final String? chatId;
  final bool isPinned;
  final bool isGenerating;
  final bool isStopped;
  final StreamController<ChatInfo> chatInfoStream;

  const ChatScreen({super.key, this.initialMessages, this.initialMessage, this.chatId, this.isPinned = false, this.isGenerating = false, this.isStopped = false, required this.chatInfoStream});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  late List<ChatMessage> _messages;
  String _currentModelResponse = '';
  bool _isStreaming = false;
  bool _isStoppedByUser = false;
  
  GenerativeModel? _geminiModel;
  ChatSession? _geminiChat;
  String _selectedChatModel = ChatModels.gemini;
  bool _isModelSetupComplete = false;

  StreamSubscription? _streamSubscription;
  http.Client? _httpClient;

  final ValueNotifier<String> _codeStreamNotifier = ValueNotifier('');
  late String _chatId;
  late bool _isPinned;
  String _chatTitle = "New Chat";
  bool _isWebSearchEnabled = false;
  bool _isThinkingModeEnabled = false;
  List<SearchResult>? _lastSearchResults;

  @override
  void initState() {
    super.initState();
    _messages = widget.initialMessages != null ? List.from(widget.initialMessages!) : [];
    _isPinned = widget.isPinned;
    _chatId = widget.chatId ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    if (_messages.isNotEmpty) {
      final firstUserMessage = _messages.firstWhere((m) => m.role == 'user', orElse: () => ChatMessage(role: 'user', text: ''));
      _chatTitle = firstUserMessage.text.length > 30 ? '${firstUserMessage.text.substring(0, 30)}...' : firstUserMessage.text.trim().isEmpty ? "New Chat" : firstUserMessage.text;
    }
    
    _isStreaming = widget.isGenerating;
    _isStoppedByUser = widget.isStopped;

    _initialize();
  }

  Future<void> _initialize() async {
    await _setupChatModel();
    _isModelSetupComplete = true;

    if (widget.initialMessage != null && mounted) {
      _controller.text = widget.initialMessage!;
      _sendMessage(widget.initialMessage!);
    }
  }

  Future<void> _setupChatModel() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedChatModel = prefs.getString('chat_model') ?? ChatModels.gemini;
    
    _geminiModel = GenerativeModel(model: ApiConfig.geminiChatModel, apiKey: ApiConfig.geminiApiKey);
    final history = _messages.where((m) => m.type == MessageType.text).map((m) => Content(m.role == 'user' ? 'user' : 'model', [TextPart(m.text)])).toList();
    _geminiChat = _geminiModel!.startChat(history: history);

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _streamSubscription?.cancel();
    _httpClient?.close();
    _codeStreamNotifier.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String input) async {
    if (!_isModelSetupComplete || _isStreaming || input.trim().isEmpty) return;
    
    _isStoppedByUser = false;
    _lastSearchResults = null;
    final userMessage = ChatMessage(role: 'user', text: input);
    
    setState(() {
      _messages.add(userMessage);
      _messages.add(ChatMessage(role: 'model', text: ''));
      _isStreaming = true;
      if (_chatTitle == "New Chat" || _chatTitle.trim().isEmpty) {
        _chatTitle = userMessage.text.length > 30 ? '${userMessage.text.substring(0, 30)}...' : userMessage.text;
      }
    });
    _controller.clear();
    _scrollToBottom();
    _updateChatInfo(true, false);

    String? webContext;
    if (_isWebSearchEnabled) {
      setState(() => _messages[_messages.length - 1] = ChatMessage(role: 'model', text: 'Searching the web...'));
      _scrollToBottom();
      final searchResponse = await WebSearchService.search(input);
      if (searchResponse != null) {
        webContext = searchResponse.promptContent;
        _lastSearchResults = searchResponse.results;
      }
    }

    if (_isThinkingModeEnabled) {
      _sendMessageOpenRouter(input, webSearchResults: webContext);
    } else if (_selectedChatModel == ChatModels.gemini) {
      _sendMessageGemini(input, webSearchResults: webContext);
    } else {
      _sendMessagePollinations(input, webSearchResults: webContext);
    }
  }
  
  String _buildHistoryContext() {
    if (_messages.length <= 1) return "";
    final history = _messages.sublist(0, _messages.length - 1);
    return history.map((m) => "${m.role == 'user' ? 'User' : 'AI'}: ${m.text}").join('\n');
  }

  Future<void> _sendMessageOpenRouter(String input, {String? webSearchResults}) async {
    setState(() {
      _messages[_messages.length - 1] = ChatMessage(role: 'model', text: '');
      _currentModelResponse = '';
    });
    _scrollToBottom();

    _httpClient = http.Client();
    try {
      final now = DateTime.now().toIso8601String();
      String finalPrompt = "System Knowledge: The current date is $now.\n\nUser Prompt: $input";
      if (webSearchResults != null && webSearchResults.isNotEmpty) {
        finalPrompt = """Use the following context to answer the user's prompt.\n---\nCONTEXT:\n1. Current Date: $now\n2. Web Search Results:\n$webSearchResults\n---\nUSER PROMPT:\n$input""";
      }

      final history = _messages.map((m) {
        return {"role": m.role == 'user' ? "user" : "assistant", "content": m.text};
      }).toList();
      history.removeLast();
      history.add({"role": "user", "content": finalPrompt});

      final request = http.Request('POST', Uri.parse(ApiConfig.openRouterChatUrl))
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${ApiConfig.openRouterApiKey}',
        })
        ..body = jsonEncode({
          'model': ApiConfig.openRouterModel,
          'messages': history,
          'stream': true,
        });

      final response = await _httpClient!.send(request);
      
      String buffer = '';
      _streamSubscription = response.stream.transform(utf8.decoder).listen(
        (chunk) {
          if (_isStoppedByUser) { _streamSubscription?.cancel(); return; }
          
          buffer += chunk;
          while (true) {
            final lineEnd = buffer.indexOf('\n');
            if (lineEnd == -1) break;

            final line = buffer.substring(0, lineEnd).trim();
            buffer = buffer.substring(lineEnd + 1);

            if (line.startsWith('data: ')) {
              final data = line.substring(6);
              if (data == '[DONE]') {
                 return;
              }

              try {
                final parsed = jsonDecode(data);
                final content = parsed['choices']?[0]?['delta']?['content'];
                if (content != null) {
                  _currentModelResponse += content;
                  setState(() {
                    _messages[_messages.length - 1] = ChatMessage(role: 'model', text: _currentModelResponse);
                  });
                   _scrollToBottom();
                }
              } catch (e) {
                // Ignore parsing errors for incomplete JSON chunks
              }
            }
          }
        },
        onDone: () {
          _httpClient?.close();
          _onStreamingDone();
        },
        onError: (error) {
          _httpClient?.close();
          _onStreamingError(error);
        },
        cancelOnError: true,
      );

    } catch (e) {
      _httpClient?.close();
      _onStreamingError(e);
    }
  }


  void _sendMessageGemini(String input, {String? webSearchResults}) {
    try {
      setState(() => _messages[_messages.length - 1] = ChatMessage(role: 'model', text: ''));
      _currentModelResponse = '';
      _scrollToBottom();

      String finalContent;
      final now = DateTime.now().toIso8601String();

      if (webSearchResults != null && webSearchResults.isNotEmpty) {
        finalContent = """Use the following context to answer the user's prompt.\n---\nCONTEXT:\n1. Current Date: $now\n2. Web Search Results:\n$webSearchResults\n---\nUSER PROMPT:\n$input""";
      } else {
        finalContent = "System Knowledge: The current date is $now.\n\nUser Prompt: $input";
      }

      final responseStream = _geminiChat!.sendMessageStream(Content.text(finalContent));
      bool isCodeSheetShown = false;
      _streamSubscription = responseStream.listen(
        (chunk) {
          if (_isStoppedByUser) { _streamSubscription?.cancel(); return; }
          _currentModelResponse += chunk.text ?? '';
          setState(() => _messages[_messages.length - 1] = ChatMessage(role: 'model', text: _currentModelResponse));
          if (_currentModelResponse.contains('```') && !isCodeSheetShown) {
            isCodeSheetShown = true;
            _codeStreamNotifier.value = '';
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Theme.of(context).scaffoldBackgroundColor, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (_) => CodeStreamingSheet(notifier: _codeStreamNotifier));
            });
          }
          if (isCodeSheetShown) {
            final codeMatch = RegExp(r'```(?:\w+)?\n([\s\S]*?)(?:```|$)').firstMatch(_currentModelResponse);
            _codeStreamNotifier.value = codeMatch?.group(1) ?? '';
          }
          _scrollToBottom();
        },
        onDone: () => _onStreamingDone(),
        onError: (error) => _onStreamingError(error),
        cancelOnError: true,
      );
    } catch (e) {
      _onStreamingError(e);
    }
  }

  Future<void> _sendMessagePollinations(String input, {String? webSearchResults}) async {
    try {
      setState(() => _messages[_messages.length - 1] = ChatMessage(role: 'model', text: ''));
      _scrollToBottom();
      
      final historyContext = _buildHistoryContext();
      final now = DateTime.now().toIso8601String();

      String finalPrompt;
      if (webSearchResults != null && webSearchResults.isNotEmpty) {
        finalPrompt = """Conversation History:\n$historyContext\n---\nBased on this context:\nDate: $now\nWeb Results: $webSearchResults\n---\nAnswer this prompt: $input""";
      } else {
        finalPrompt = """Conversation History:\n$historyContext\n---\nCurrent date is $now. Answer: $input""";
      }

      final url = ApiConfig.getPollinationsChatUrl(finalPrompt, _selectedChatModel);
      final response = await http.get(Uri.parse(url));

      if (_isStoppedByUser) { _onStreamingDone(); return; }

      if (response.statusCode == 200) {
        final output = utf8.decode(response.bodyBytes);
        setState(() {
            _messages[_messages.length - 1] = ChatMessage(role: 'model', text: output.trim());
        });
      } else {
        _onStreamingError('Pollinations API Error: ${response.statusCode}');
      }
    } catch (e) {
      _onStreamingError(e);
    } finally {
      _onStreamingDone();
    }
  }
  
  void _onStreamingDone() {
    if (_lastSearchResults != null && _messages.isNotEmpty) {
      final lastMessage = _messages.last;
      _messages[_messages.length - 1] = ChatMessage(
        role: lastMessage.role,
        text: lastMessage.text,
        type: lastMessage.type,
        imageUrl: lastMessage.imageUrl,
        slides: lastMessage.slides,
        searchResults: _lastSearchResults,
      );
      _lastSearchResults = null;
    }
    // Refresh Gemini chat history after each turn
    _setupChatModel(); 
    
    setState(() => _isStreaming = false);
    _updateChatInfo(false, false);
    _scrollToBottom();
  }

  void _onStreamingError(dynamic error) {
    setState(() {
      _messages[_messages.length - 1] = ChatMessage(role: 'model', text: '❌ Error: $error');
      _isStreaming = false;
    });
    _updateChatInfo(false, false);
    _scrollToBottom();
  }
  
  void _updateChatInfo(bool isGenerating, bool isStopped) {
    final category = _determineCategory(_messages);
    final chatInfo = ChatInfo(id: _chatId, title: _chatTitle, messages: List.from(_messages), isPinned: _isPinned, isGenerating: isGenerating, isStopped: isStopped, category: category);
    widget.chatInfoStream.add(chatInfo);
  }

  void _stopStreaming() {
    _streamSubscription?.cancel();
    _httpClient?.close();
    setState(() {
      _isStreaming = false;
      _isStoppedByUser = true;
    });
    _updateChatInfo(false, true);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  void _showToolsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 5,
                      decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: const Text('Search the web'),
                    trailing: Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _isWebSearchEnabled,
                        onChanged: (bool value) {
                          setSheetState(() => _isWebSearchEnabled = value);
                          setState(() => _isWebSearchEnabled = value);
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Web search is now ${value ? "ON" : "OFF"}.'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              margin: EdgeInsets.only(left: 12, right: 12, bottom: 90 + MediaQuery.of(context).viewInsets.bottom),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                   ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: const Text('Think before responding'),
                    trailing: Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _isThinkingModeEnabled,
                        onChanged: (bool value) {
                          setSheetState(() => _isThinkingModeEnabled = value);
                          setState(() => _isThinkingModeEnabled = value);
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Deep thinking mode is now ${value ? "ON" : "OFF"}.'),
                              duration: const Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              margin: EdgeInsets.only(left: 12, right: 12, bottom: 90 + MediaQuery.of(context).viewInsets.bottom),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: const Text('Create an image'),
                    onTap: () {
                      Navigator.pop(context);
                      _showImagePromptBottomSheet();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.slideshow_outlined),
                    title: const Text('Make a presentation'),
                    onTap: () {
                      Navigator.pop(context);
                      _showPresentationPromptDialog();
                    },
                  ),
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showImagePromptBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return ImagePromptSheet(
          onGenerate: (prompt, model) {
            _generateImage(prompt, model);
          },
        );
      },
    );
  }

  Future<void> _generateImage(String prompt, String? model) async {
    final userMessage = ChatMessage(role: 'user', text: prompt);
    final imageUrl = ImageApi.getImageUrl(prompt, model: model);
    
    final imageMessage = ChatMessage(role: 'model', text: 'Image for: $prompt', type: MessageType.image, imageUrl: imageUrl);
    final placeholderMessage = ChatMessage(role: 'model', text: 'Generating image...', type: MessageType.image, imageUrl: null);
    
    setState(() {
      _messages.add(userMessage);
      _messages.add(placeholderMessage);
    });
    _scrollToBottom();
    final int placeholderIndex = _messages.length - 1;

    try {
      await precacheImage(NetworkImage(imageUrl), context);
      if (mounted) {
        setState(() => _messages[placeholderIndex] = imageMessage);
      }
    } catch(e) {
      if (mounted) {
        setState(() => _messages[placeholderIndex] = ChatMessage(role: 'model', text: '❌ Failed to load image.', type: MessageType.text));
      }
    } finally {
        _updateChatInfo(false, false);
    }
  }
  
  void _showPresentationPromptDialog() {
    final TextEditingController promptController = TextEditingController();
    showDialog(context: context, builder: (context) {
      return AlertDialog(
        backgroundColor: Theme.of(context).dialogBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Presentation Topic'),
        content: TextField(controller: promptController, autofocus: true, decoration: const InputDecoration(hintText: 'e.g., The History of Space Exploration'), onSubmitted: (topic) {
          if (topic.trim().isNotEmpty) {
            Navigator.of(context).pop();
            _generatePresentation(topic);
          }
        }),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () {
            final topic = promptController.text;
            if (topic.trim().isNotEmpty) {
              Navigator.of(context).pop();
              _generatePresentation(topic);
            }
          }, child: const Text('Generate')),
        ],
      );
    });
  }

  Future<void> _generatePresentation(String topic) async {
    _messages.add(ChatMessage(role: 'user', text: topic));
    _messages.add(ChatMessage(role: 'model', text: 'Generating presentation...', type: MessageType.presentation, slides: null));
    final int placeholderIndex = _messages.length - 1;

    setState(() {});
    _scrollToBottom();

    final slides = await PresentationGenerator.generateSlides(topic, ApiConfig.geminiApiKey);
    
    if (!mounted) return;

    if (slides.isNotEmpty) {
      setState(() => _messages[placeholderIndex] = ChatMessage(role: 'model', text: 'Presentation ready: $topic', type: MessageType.presentation, slides: slides));
      Navigator.push(context, MaterialPageRoute(builder: (context) => PresentationViewScreen(slides: slides, topic: topic)));
    } else {
      setState(() => _messages[placeholderIndex] = ChatMessage(role: 'model', text: 'Could not generate presentation for "$topic". Please try again.', type: MessageType.text));
    }
    _updateChatInfo(false, false);
  }

  Widget _buildMessage(ChatMessage message) {
    switch (message.type) {
      case MessageType.image:
        if (message.imageUrl == null) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Generating image...'),
                const SizedBox(width: 12),
                GeneratingIndicator(size: 16),
              ]),
            ),
          );
        } else {
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
              constraints: const BoxConstraints(maxWidth: 250, maxHeight: 250),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  message.imageUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, progress) => progress == null ? child : const Center(child: CircularProgressIndicator()),
                  errorBuilder: (context, error, stack) => const Icon(Icons.error),
                ),
              ),
            ),
          );
        }

      case MessageType.presentation:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
            child: message.slides == null
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Generating presentation...'),
                    const SizedBox(width: 12),
                    GeneratingIndicator(size: 16),
                  ])
                : InkWell(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => PresentationViewScreen(slides: message.slides!, topic: message.text.replaceFirst('Presentation ready: ', '')))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.slideshow, size: 20), const SizedBox(width: 12), Flexible(child: Text(message.text, style: const TextStyle(fontWeight: FontWeight.bold)))]),
                  ),
          ),
        );

      case MessageType.text:
      default:
        if (message.role == 'model') {
          final isModelMessage = message.role == 'model';

          if (message.text.isEmpty && _isStreaming) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
                child: const GeneratingIndicator(),
              ),
            );
          }
          if (message.text == 'Searching the web...' || message.text == 'Thinking deeply...') {
             return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(16)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(message.text),
                  const SizedBox(width: 12),
                  GeneratingIndicator(size: 16),
                ]),
              ),
            );
          }
          return Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: MarkdownBody(data: message.text, selectable: true, styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))),
                ),
                if (isModelMessage && message.searchResults != null && message.searchResults!.isNotEmpty)
                  _buildSearchResultsWidget(message.searchResults!),
              ],
            ),
          );
        }
        final isDark = !isLightTheme(context);
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Theme.of(context).elevatedButtonTheme.style?.backgroundColor?.resolve({}), borderRadius: BorderRadius.circular(16)),
            child: MarkdownBody(
              data: message.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: Theme.of(context).textTheme.bodyLarge?.copyWith(color: isDark ? draculaBackground : Colors.white),
                code: Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', backgroundColor: isDark ? Colors.black.withOpacity(0.2) : Colors.black.withOpacity(0.15), color: isDark ? Colors.white : Colors.white),
              ),
            ),
          ),
        );
    }
  }

  Widget _buildSearchResultsWidget(List<SearchResult> results) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 22, top: 8, bottom: 8),
          child: Text("Sources", style: Theme.of(context).textTheme.titleSmall),
        ),
        SizedBox(
          height: 90,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final result = results[index];
              return _SearchResultCard(result: result);
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_chatTitle), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) => _buildMessage(_messages[index]),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + MediaQuery.of(context).padding.bottom),
            decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, border: Border(top: BorderSide(color: Theme.of(context).dividerColor, width: 1.0))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(icon: const Icon(Icons.apps_outlined), onPressed: _isStreaming ? null : _showToolsBottomSheet, tooltip: 'Tools', color: _isStreaming ? Theme.of(context).disabledColor : Theme.of(context).iconTheme.color),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: !_isStreaming,
                    onSubmitted: _isStreaming ? null : (val) => _sendMessage(val),
                    textInputAction: TextInputAction.send,
                    maxLines: 5,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: _isStreaming ? 'Aham is responding...' : 'Ask Aham anything...', 
                      filled: true, 
                      fillColor: Theme.of(context).cardColor, 
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), 
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: _isStreaming ? Colors.red : Theme.of(context).elevatedButtonTheme.style?.backgroundColor?.resolve({}),
                  radius: 24,
                  child: IconButton(
                    icon: Icon(_isStreaming ? Icons.stop : Icons.arrow_upward, color: Theme.of(context).elevatedButtonTheme.style?.foregroundColor?.resolve({})),
                    onPressed: _isStreaming ? _stopStreaming : () => _sendMessage(_controller.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({required this.result});

  final SearchResult result;

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
       print('Could not launch $uri');
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _launchUrl(result.url),
      child: Container(
        width: 140,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (result.faviconUrl != null)
                  Image.network(
                    result.faviconUrl!,
                    height: 16,
                    width: 16,
                    errorBuilder: (_, __, ___) => const Icon(Icons.public, size: 16),
                  )
                else
                  const Icon(Icons.public, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    Uri.parse(result.url).host,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                result.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ImagePromptSheet extends StatefulWidget {
  final Function(String prompt, String model) onGenerate;
  const ImagePromptSheet({super.key, required this.onGenerate});

  @override
  State<ImagePromptSheet> createState() => _ImagePromptSheetState();
}

class _ImagePromptSheetState extends State<ImagePromptSheet> {
  final _promptController = TextEditingController();
  String? _selectedModel;
  
  void _submit() {
    if (_promptController.text.trim().isNotEmpty && _selectedModel != null) {
      widget.onGenerate(_promptController.text.trim(), _selectedModel!);
      Navigator.pop(context);
    }
  }

  void _showModelSelection() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        return FutureBuilder<List<String>>(
          future: ImageApi.fetchModels(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(heightFactor: 4, child: CircularProgressIndicator());
            }
            final models = snapshot.data!;
            return ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: models.length,
              itemBuilder: (context, index) {
                final model = models[index];
                return ListTile(
                  title: Text(model),
                  trailing: _selectedModel == model ? Icon(Icons.check_circle, color: Theme.of(context).primaryColor) : null,
                  onTap: () {
                    setState(() => _selectedModel = model);
                    Navigator.pop(context);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    ImageApi.fetchModels().then((models) {
      if (mounted && models.isNotEmpty) {
        setState(() => _selectedModel = models.first);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Text('Generate Image', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _promptController,
            autofocus: true,
            decoration: InputDecoration(hintText: 'e.g., A fox in a spacesuit', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _showModelSelection,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_selectedModel ?? 'Select a model...'),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.generating_tokens_outlined),
              label: const Text('Generate'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GeneratingIndicator extends StatefulWidget {
  final double size;
  const GeneratingIndicator({super.key, this.size = 12});
  @override
  _GeneratingIndicatorState createState() => _GeneratingIndicatorState();
}

class _GeneratingIndicatorState extends State<GeneratingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 800), vsync: this)..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Opacity(opacity: _animation.value, child: Icon(Icons.circle, size: widget.size, color: Theme.of(context).elevatedButtonTheme.style?.backgroundColor?.resolve({}))),
    );
  }
}

class CodeStreamingSheet extends StatelessWidget {
  final ValueNotifier<String> notifier;
  const CodeStreamingSheet({super.key, required this.notifier});
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text('Generated Code', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20)),
              const SizedBox(height: 12),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: notifier,
                  builder: (context, code, _) => SingleChildScrollView(controller: controller, child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 14))),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final code = notifier.value;
                    if (code.trim().isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Code copied to clipboard!")));
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text("Copy Code"),
                  style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        );
      },
    );
  }
}

String _determineCategory(List<ChatMessage> messages) {
  final userMessages = messages.where((m) => m.role == 'user').map((m) => m.text.toLowerCase()).join(' ');

  if (userMessages.contains('code') || userMessages.contains('programming') || userMessages.contains('debug') || userMessages.contains('flutter') || userMessages.contains('python')) return 'Coding';
  if (userMessages.contains('write') || userMessages.contains('poem') || userMessages.contains('story') || userMessages.contains('script') || userMessages.contains('lyrics')) return 'Creative';
  if (userMessages.contains('science') || userMessages.contains('physics') || userMessages.contains('biology') || userMessages.contains('chemistry') || userMessages.contains('astronomy')) return 'Science';
  if (userMessages.contains('health') || userMessages.contains('medical') || userMessages.contains('fitness') || userMessages.contains('diet') || userMessages.contains('wellness')) return 'Health';
  if (userMessages.contains('history') || userMessages.contains('ancient') || userMessages.contains('war') || userMessages.contains('historical')) return 'History';
  if (userMessages.contains('tech') || userMessages.contains('gadget') || userMessages.contains('software') || userMessages.contains('computer') || userMessages.contains('ai')) return 'Technology';
  if (userMessages.contains('plan') || userMessages.contains('trip') || userMessages.contains('schedule') || userMessages.contains('travel') || userMessages.contains('itinerary') || userMessages.contains('vacation')) return 'Travel & Plans';
  if (userMessages.contains('weather') || userMessages.contains('forecast') || userMessages.contains('temperature')) return 'Weather';
  if (userMessages.contains('fact') || userMessages.contains('trivia') || userMessages.contains('knowledge')) return 'Facts';
  
  return 'General';
}