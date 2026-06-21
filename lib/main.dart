import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const RubikaApp());

class RubikaApp extends StatelessWidget {
  const RubikaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مدیریت ربات روبیکا',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF2DB2FF)),
      ),
      home: const SplashScreen(),
    );
  }
}

// ==================== SPLASH ====================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    await Future.delayed(const Duration(seconds: 1));
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (!mounted) return;
    if (token != null && token.isNotEmpty) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatsScreen(token: token)));
    } else {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator(color: Color(0xFF2DB2FF))),
    );
  }
}

// ==================== API ====================
class RubikaApi {
  static const String baseUrl = 'https://botapi.rubika.ir';
  final String token;
  RubikaApi(this.token);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'auth': token,
      };

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/v1/$endpoint'),
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));
      return jsonDecode(response.body);
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> getMe() => _post('getMe', {});

  Future<Map<String, dynamic>> getUpdates({int offset = 0}) =>
      _post('getupdates', {'offset': offset});

  Future<Map<String, dynamic>> sendMessage({
    required String chatId,
    required String text,
    String? replyToMessageId,
  }) =>
      _post('sendMessage', {
        'chat_id': chatId,
        'text': text,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      });

  Future<Map<String, dynamic>> editMessage({
    required String chatId,
    required String messageId,
    required String text,
  }) =>
      _post('editMessage', {
        'chat_id': chatId,
        'message_id': messageId,
        'text': text,
      });

  Future<Map<String, dynamic>> deleteMessage({
    required String chatId,
    required String messageId,
  }) =>
      _post('deleteMessage', {
        'chat_id': chatId,
        'message_id': messageId,
      });

  Future<Map<String, dynamic>> sendMessageWithKeypad({
    required String chatId,
    required String text,
    required List<List<Map<String, String>>> buttons,
  }) =>
      _post('sendMessage', {
        'chat_id': chatId,
        'text': text,
        'chat_keypad_type': 'New',
        'chat_keypad': {
          'rows': buttons.map((row) => {
            'buttons': row.map((btn) => {
              'id': btn['id'] ?? UniqueKey().toString(),
              'type': 'Simple',
              'button_text': btn['text'] ?? '',
            }).toList(),
          }).toList(),
          'resize_keyboard': true,
          'on_time_keyboard': false,
        },
      });

  Future<Map<String, dynamic>?> _uploadFile(File file, String type) async {
    try {
      final bytes = await file.readAsBytes();
      final base64File = base64Encode(bytes);
      final fileName = file.path.split('/').last;
      String mime = 'application/octet-stream';
      if (type == 'Image') mime = 'image/jpeg';
      if (type == 'Voice') mime = 'audio/ogg';
      if (type == 'Video') mime = 'video/mp4';
      final result = await _post('uploadFile', {
        'file_name': fileName,
        'mime': mime,
        'file': base64File,
        'type': type,
      });
      if (result['ok'] == true) return result['result'];
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> sendFile({
    required String chatId,
    required File file,
    required String type,
    String? caption,
    String? replyToMessageId,
  }) async {
    final uploaded = await _uploadFile(file, type);
    if (uploaded == null) return {'ok': false, 'error': 'خطا در آپلود'};

    final fileData = {
      'file_id': uploaded['file_id'],
      'dc_id': uploaded['dc_id'],
      'access_hash_send': uploaded['access_hash_send'],
    };

    final endpointMap = {
      'Image': 'sendPhoto',
      'Voice': 'sendVoice',
      'Video': 'sendVideo',
      'File': 'sendDocument',
    };

    final fileKey = type == 'Image'
        ? 'photo'
        : type == 'Voice'
            ? 'voice'
            : type == 'Video'
                ? 'video'
                : 'document';

    return _post(endpointMap[type] ?? 'sendDocument', {
      'chat_id': chatId,
      fileKey: fileData,
      if (caption != null) 'caption': caption,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
    });
  }
}

// ==================== LOGIN ====================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    final token = _ctrl.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'توکن را وارد کنید');
      return;
    }
    setState(() { _loading = true; _error = null; });
    final api = RubikaApi(token);
    final result = await api.getMe();
    if (result['ok'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ChatsScreen(token: token)),
        );
      }
    } else {
      setState(() => _error = 'توکن نامعتبر است');
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.smart_toy, size: 90, color: Color(0xFF2DB2FF)),
              const SizedBox(height: 20),
              const Text('مدیریت ربات روبیکا',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('توکن ربات خود را وارد کنید',
                  style: TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 40),
              TextField(
                controller: _ctrl,
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Bot Token',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF1C2128),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.key, color: Color(0xFF2DB2FF)),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2DB2FF),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('ورود', style: TextStyle(fontSize: 17, color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== CHATS ====================
class ChatsScreen extends StatefulWidget {
  final String token;
  const ChatsScreen({super.key, required this.token});
  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  late RubikaApi _api;
  final Map<String, Map<String, dynamic>> _chats = {};
  final Map<String, List<Map<String, dynamic>>> _messages = {};
  int _offset = 0;
  Timer? _timer;
  bool _firstLoad = true;
  String? _botName;

  @override
  void initState() {
    super.initState();
    _api = RubikaApi(widget.token);
    _loadBotInfo();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadBotInfo() async {
    final result = await _api.getMe();
    if (result['ok'] == true && mounted) {
      setState(() => _botName = result['result']?['first_name'] ?? 'ربات');
    }
  }

  Future<void> _poll() async {
    final result = await _api.getUpdates(offset: _offset);
    if (result['ok'] == true) {
      final updates = (result['result']?['updated_list'] as List?) ?? [];
      for (final upd in updates) {
        final chatId = upd['chat_id']?.toString() ??
            upd['message']?['chat_id']?.toString();
        if (chatId == null) continue;

        final msg = upd['message'] as Map<String, dynamic>? ?? {};
        final text = msg['text']?.toString() ??
            (msg['type'] == 'Image' ? '📷 عکس' :
             msg['type'] == 'Voice' ? '🎤 ویس' :
             msg['type'] == 'Video' ? '🎥 ویدیو' :
             msg['type'] == 'File'  ? '📎 فایل' : 'پیام جدید');
        final msgId = msg['message_id']?.toString() ?? '';
        final senderId = msg['author_object_guid']?.toString() ?? '';

        setState(() {
          _chats[chatId] = {
            'chat_id': chatId,
            'last_message': text,
            'last_time': DateTime.now().millisecondsSinceEpoch,
            'unread': (_chats[chatId]?['unread'] ?? 0) + 1,
          };
          _messages[chatId] ??= [];
          _messages[chatId]!.add({
            'id': msgId,
            'text': text,
            'type': msg['type'] ?? 'Text',
            'from_me': false,
            'sender_id': senderId,
            'time': DateTime.now().millisecondsSinceEpoch,
          });
        });

        final updateId = upd['update_id'];
        if (updateId != null) _offset = (updateId as int) + 1;
      }
    }
    if (_firstLoad && mounted) setState(() => _firstLoad = false);
  }

  Future<void> _logout() async {
    _timer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    if (mounted) {
      Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    final sortedChats = _chats.values.toList()
      ..sort((a, b) => (b['last_time'] as int).compareTo(a['last_time'] as int));

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: Row(children: [
          const Icon(Icons.smart_toy, color: Color(0xFF2DB2FF)),
          const SizedBox(width: 8),
          Text(_botName ?? 'ربات روبیکا', style: const TextStyle(color: Colors.white)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: _logout,
            tooltip: 'خروج',
          ),
        ],
      ),
      body: _firstLoad
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF2DB2FF)))
          : sortedChats.isEmpty
              ? const Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.forum_outlined, size: 70, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('هنوز پیامی نرسیده', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    SizedBox(height: 8),
                    Text('منتظر پیام کاربران باشید...', style: TextStyle(color: Colors.grey54, fontSize: 13)),
                  ]),
                )
              : ListView.separated(
                  itemCount: sortedChats.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Color(0xFF21262D), height: 1),
                  itemBuilder: (context, i) {
                    final chat = sortedChats[i];
                    final chatId = chat['chat_id'] as String;
                    final unread = chat['unread'] as int? ?? 0;
                    return ListTile(
                      onTap: () {
                        setState(() => _chats[chatId]?['unread'] = 0);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MessagesScreen(
                              token: widget.token,
                              chatId: chatId,
                              initialMessages: List.from(_messages[chatId] ?? []),
                              onNewMessage: (msgs) {
                                setState(() => _messages[chatId] = msgs);
                              },
                            ),
                          ),
                        );
                      },
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF2DB2FF),
                        child: Text(
                          chatId.substring(1, 2).toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      title: Text(
                        'چت ${chatId.substring(0, 12)}...',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        chat['last_message'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(_formatTime(chat['last_time'] ?? 0),
                              style: const TextStyle(color: Colors.grey, fontSize: 11)),
                          if (unread > 0) ...[
                            const SizedBox(height: 4),
                            CircleAvatar(
                              radius: 10,
                              backgroundColor: const Color(0xFF2DB2FF),
                              child: Text('$unread',
                                  style: const TextStyle(color: Colors.white, fontSize: 10)),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

// ==================== MESSAGES ====================
class MessagesScreen extends StatefulWidget {
  final String token;
  final String chatId;
  final List<Map<String, dynamic>> initialMessages;
  final void Function(List<Map<String, dynamic>>) onNewMessage;

  const MessagesScreen({
    super.key,
    required this.token,
    required this.chatId,
    required this.initialMessages,
    required this.onNewMessage,
  });

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late RubikaApi _api;
  late List<Map<String, dynamic>> _messages;
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _timer;
  int _offset = 0;
  bool _isRecording = false;
  String? _replyId;
  String? _replyText;
  String? _editId;
  final _recorder = AudioRecorder();
  String? _recordPath;

  @override
  void initState() {
    super.initState();
    _api = RubikaApi(widget.token);
    _messages = List.from(widget.initialMessages);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    _scrollToBottom();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    widget.onNewMessage(_messages);
    super.dispose();
  }

  Future<void> _poll() async {
    final result = await _api.getUpdates(offset: _offset);
    if (result['ok'] == true) {
      final updates = (result['result']?['updated_list'] as List?) ?? [];
      for (final upd in updates) {
        final chatId = upd['chat_id']?.toString() ??
            upd['message']?['chat_id']?.toString();
        if (chatId != widget.chatId) continue;
        final msg = upd['message'] as Map<String, dynamic>? ?? {};
        final text = msg['text']?.toString() ??
            (msg['type'] == 'Image' ? '📷 عکس' :
             msg['type'] == 'Voice' ? '🎤 ویس' :
             msg['type'] == 'Video' ? '🎥 ویدیو' :
             msg['type'] == 'File'  ? '📎 فایل' : 'پیام');
        final msgId = msg['message_id']?.toString() ?? DateTime.now().toString();
        final already = _messages.any((m) => m['id'] == msgId);
        if (!already) {
          setState(() => _messages.add({
            'id': msgId,
            'text': text,
            'type': msg['type'] ?? 'Text',
            'from_me': false,
            'time': DateTime.now().millisecondsSinceEpoch,
          }));
          _scrollToBottom();
        }
        final updateId = upd['update_id'];
        if (updateId != null) _offset = (updateId as int) + 1;
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _sendText() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();

    if (_editId != null) {
      final id = _editId!;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == id);
        if (idx >= 0) _messages[idx]['text'] = text;
        _editId = null;
        _replyText = null;
      });
      await _api.editMessage(chatId: widget.chatId, messageId: id, text: text);
      return;
    }

    final tmpId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _messages.add({
        'id': tmpId,
        'text': text,
        'type': 'Text',
        'from_me': true,
        'time': DateTime.now().millisecondsSinceEpoch,
        'reply_text': _replyText,
      });
      _replyId = null;
      _replyText = null;
    });
    _scrollToBottom();
    await _api.sendMessage(
        chatId: widget.chatId, text: text, replyToMessageId: _replyId);
  }

  Future<void> _sendImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    _addLocalMsg('📷 عکس', 'Image');
    await _api.sendFile(
        chatId: widget.chatId, file: File(picked.path), type: 'Image');
  }

  Future<void> _sendVideo() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    _addLocalMsg('🎥 ویدیو', 'Video');
    await _api.sendFile(
        chatId: widget.chatId, file: File(picked.path), type: 'Video');
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path!;
    final name = result.files.first.name;
    _addLocalMsg('📎 $name', 'File');
    await _api.sendFile(
        chatId: widget.chatId, file: File(path), type: 'File');
  }

  void _addLocalMsg(String text, String type) {
    setState(() => _messages.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'text': text,
      'type': type,
      'from_me': true,
      'time': DateTime.now().millisecondsSinceEpoch,
    }));
    _scrollToBottom();
  }

  Future<void> _startRecord() async {
    await Permission.microphone.request();
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    _recordPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc), path: _recordPath!);
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecord() async {
    await _recorder.stop();
    setState(() => _isRecording = false);
    if (_recordPath == null) return;
    _addLocalMsg('🎤 ویس', 'Voice');
    await _api.sendFile(
        chatId: widget.chatId, file: File(_recordPath!), type: 'Voice');
  }

  void _showOptions(Map<String, dynamic> msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C2128),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4, decoration: BoxDecoration(
            color: Colors.grey, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.reply, color: Color(0xFF2DB2FF)),
            title: const Text('پاسخ', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              setState(() { _replyId = msg['id']; _replyText = msg['text']; _editId = null; });
            },
          ),
          if (msg['from_me'] == true) ...[
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.orangeAccent),
              title: const Text('ویرایش', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                setState(() { _editId = msg['id']; _ctrl.text = msg['text']; _replyText = '✏️ ویرایش پیام'; });
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('حذف', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                setState(() => _messages.removeWhere((m) => m['id'] == msg['id']));
                _api.deleteMessage(chatId: widget.chatId, messageId: msg['id']);
              },
            ),
          ],
        ],
      ),
    );
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('گفتگو', style: TextStyle(color: Colors.white, fontSize: 16)),
          Text(
            widget.chatId.length > 14
                ? '${widget.chatId.substring(0, 14)}...'
                : widget.chatId,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Text('هنوز پیامی نیست', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _buildBubble(_messages[i]),
                ),
        ),

        // نوار ریپلای/ویرایش
        if (_replyText != null)
          Container(
            color: const Color(0xFF161B22),
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(children: [
              Icon(
                _editId != null ? Icons.edit : Icons.reply,
                color: const Color(0xFF2DB2FF), size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_replyText!,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.grey, size: 18),
                onPressed: () => setState(() { _replyId = null; _replyText = null; _editId = null; _ctrl.clear(); }),
              ),
            ]),
          ),

        // نوار ورودی
        Container(
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.attach_file, color: Color(0xFF2DB2FF)),
              color: const Color(0xFF1C2128),
              onSelected: (v) {
                if (v == 'image') _sendImage();
                if (v == 'video') _sendVideo();
                if (v == 'file') _sendFile();
              },
              itemBuilder: (_) => [
                _menuItem('image', Icons.image, 'عکس'),
                _menuItem('video', Icons.videocam, 'ویدیو'),
                _menuItem('file', Icons.insert_drive_file, 'فایل'),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                textDirection: TextDirection.rtl,
                style: const TextStyle(color: Colors.white),
                maxLines: null,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: _isRecording ? '🔴 در حال ضبط...' : 'پیام...',
                  hintStyle: TextStyle(
                      color: _isRecording ? Colors.redAccent : Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF0D1117),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _ctrl.text.trim().isNotEmpty ? _sendText : null,
              onLongPressStart: (_ctrl.text.trim().isEmpty)
                  ? (_) => _startRecord()
                  : null,
              onLongPressEnd: (_ctrl.text.trim().isEmpty)
                  ? (_) => _stopRecord()
                  : null,
              child: CircleAvatar(
                backgroundColor: _isRecording
                    ? Colors.redAccent
                    : const Color(0xFF2DB2FF),
                child: Icon(
                  _isRecording
                      ? Icons.stop
                      : _ctrl.text.trim().isNotEmpty
                          ? Icons.send
                          : Icons.mic,
                  color: Colors.white,
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(children: [
        Icon(icon, color: const Color(0xFF2DB2FF)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
      ]),
    );
  }

  Widget _buildBubble(Map<String, dynamic> msg) {
    final isMe = msg['from_me'] == true;
    return GestureDetector(
      onLongPress: () => _showOptions(msg),
      child: Align(
        alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF1A3A5C) : const Color(0xFF1C2128),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 4 : 16),
              bottomRight: Radius.circular(isMe ? 16 : 4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg['reply_text'] != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: const Border(
                        left: BorderSide(color: Color(0xFF2DB2FF), width: 3)),
                  ),
                  child: Text(msg['reply_text'],
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              Text(msg['text'] ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              const SizedBox(height: 4),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_time(msg['time'] ?? 0),
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.done_all, size: 14, color: Color(0xFF2DB2FF)),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
