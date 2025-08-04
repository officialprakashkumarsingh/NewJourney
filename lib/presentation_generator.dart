import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'api.dart';
import 'theme.dart';

class PresentationGenerator {
  static Future<List<String>> generateSlides(String topic, String apiKey) async {
    final model = GenerativeModel(model: ApiConfig.presentationModelName, apiKey: apiKey);
    final prompt = """
    You are an expert presentation creator. Your task is to generate content for a slide deck on the topic: "$topic".

    Follow these rules STRICTLY:
    1.  **Slide Separation:** Separate each slide's content with '---' on a new line. This is the slide delimiter.
    2.  **Content Formatting:** Use Markdown for all content.
        *   The first slide MUST be a title slide. Use a level 1 heading (#) for the main title and a level 3 heading (###) for a subtitle or author.
        *   For subsequent slides, use level 2 headings (##) for slide titles.
        *   Use bullet points (`* `) for lists. Keep points concise.
        *   The final slide MUST be a 'Thank You' or 'Q&A' slide.
    3.  **Content Quantity:** Generate between 20 and 30 slides in total.
    4.  **Output Format:** Provide ONLY the raw markdown content with '---' as a separator. Do NOT include any other text, explanations, or code fences like ```markdown.
    """;

    try {
      final response = await model.generateContent([Content.text(prompt)]);
      final rawText = response.text ?? "";
      if (rawText.isEmpty) return [];
      return rawText.split(RegExp(r'\n---\n*'));
    } catch (e) {
      print("Error generating presentation slides: $e");
      return [];
    }
  }
}

class PresentationViewScreen extends StatefulWidget {
  final List<String> slides;
  final String topic;

  const PresentationViewScreen({
    super.key,
    required this.slides,
    required this.topic,
  });

  @override
  State<PresentationViewScreen> createState() => _PresentationViewScreenState();
}

class _PresentationViewScreenState extends State<PresentationViewScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController.addListener(() {
      setState(() {
        _currentPage = _pageController.page?.round() ?? 0;
      });
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.topic),
        elevation: 1,
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.slides.length,
        itemBuilder: (context, index) {
          final slideContent = widget.slides[index];
          return Container(
            padding: const EdgeInsets.all(24.0),
            color: Theme.of(context).cardColor,
            child: Center(
              child: Markdown(
                data: slideContent,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  h1: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
                  h2: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: draculaPurple),
                  p: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 18),
                  listBullet: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 18),
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: BottomAppBar(
        color: Colors.transparent,
        elevation: 0,
        child: SizedBox(
          height: 50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${_currentPage + 1} / ${widget.slides.length}'),
            ],
          ),
        ),
      ),
    );
  }
}