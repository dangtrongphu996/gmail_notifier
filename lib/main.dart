import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final NotificationService notificationService = NotificationService();
  await notificationService.init();
  runApp(MyApp(notificationService: notificationService));
}

/// Simple model for saved account
class SavedAccount {
  final String email;
  final String id;
  SavedAccount({required this.email, required this.id});
  Map<String, dynamic> toJson() => {'email': email, 'id': id};
  static SavedAccount fromJson(Map<String, dynamic> j) =>
      SavedAccount(email: j['email'], id: j['id']);
}

/// Provider to manage accounts & polling
class AccountProvider extends ChangeNotifier {
  final FlutterSecureStorage storage;
  final GoogleSignIn googleSignIn;
  final NotificationService notificationService;

  List<SavedAccount> accounts = [];
  Map<String, int> lastUnreadCount = {}; // email -> last unread count
  Timer? _pollTimer;
  bool polling = false;
  Duration pollInterval = Duration(seconds: 60);

  AccountProvider({
    required this.storage,
    required this.googleSignIn,
    required this.notificationService,
  }) {
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final raw = await storage.read(key: 'accounts');
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      accounts = list.map((e) => SavedAccount.fromJson(e)).toList();
    } else {
      accounts = [];
    }
    notifyListeners();
  }

  Future<void> _saveAccounts() async {
    final raw = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await storage.write(key: 'accounts', value: raw);
  }

  Future<void> addAccount() async {
    try {
      final GoogleSignInAccount? account = await googleSignIn.signIn();
      if (account == null) return; // user canceled
      final auth = await account.authentication;
      // Save a reference (email + id). We won't persist accessToken permanently.
      final sa = SavedAccount(email: account.email, id: account.id);
      // Avoid duplicates
      if (!accounts.any((a) => a.email == sa.email)) {
        accounts.add(sa);
        await _saveAccounts();
        notifyListeners();
      }
      // Save a last unread count initial as 0
      lastUnreadCount[sa.email] = 0;

      // Optionally fetch immediately
      await checkAccountUnread(account);
    } catch (e, st) {
      debugPrint('addAccount error: $e $st');
    }
  }

  Future<void> removeAccount(SavedAccount a) async {
    accounts.removeWhere((x) => x.email == a.email);
    lastUnreadCount.remove(a.email);
    await _saveAccounts();
    notifyListeners();
  }

  /// Call Gmail API to get unread count and notify if increased
  Future<void> checkAccountUnread(GoogleSignInAccount account) async {
    try {
      final auth = await account.authentication;
      final token = auth.accessToken;
      if (token == null) {
        debugPrint('No access token for ${account.email}');
        return;
      }

      // query: is:unread
      final resp = await http.get(
        Uri.parse(
          'https://gmail.googleapis.com/gmail/v1/users/me/messages?q=is:unread',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final messages = json['messages'] as List<dynamic>?;
        final int unreadCount = messages?.length ?? 0;
        final previous = lastUnreadCount[account.email] ?? 0;

        if (unreadCount > previous) {
          final newEmails = unreadCount - previous;
          await notificationService.showNotification(
            id: account.email.hashCode,
            title: 'Email mới (${account.email})',
            body: '$newEmails email chưa đọc mới',
          );
        }

        lastUnreadCount[account.email] = unreadCount;
        notifyListeners();
      } else if (resp.statusCode == 401) {
        // token expired or revoked. Try to refresh by calling authentication again
        debugPrint(
          '401: token maybe expired, try refresh for ${account.email}',
        );
        await account.authentication; // triggers google_sign_in refresh
      } else {
        debugPrint(
          'Gmail API error ${resp.statusCode} ${resp.body} for ${account.email}',
        );
      }
    } catch (e, st) {
      debugPrint('checkAccountUnread error: $e $st');
    }
  }

  /// Convenience: check all stored accounts (attempt to sign-in silently then check)
  Future<void> checkAllAccountsOnce() async {
    for (final a in accounts) {
      // attempt to get a GoogleSignInAccount corresponding to this email
      // google_sign_in does not expose a direct way to get other accounts,
      // but signIn() can pick the account if user chooses.
      // We'll try signInSilently first.
      GoogleSignInAccount? account;
      try {
        account = await googleSignIn.signInSilently();
        if (account == null || account.email != a.email) {
          // Prompt user to pick this account (interactive sign-in)
          // NOTE: for personal use this is acceptable; the user will pick the account
          account = await googleSignIn.signIn();
        }
        if (account != null) {
          if (account.email != a.email) {
            debugPrint(
              'Signed in account ${account.email}, expected ${a.email}. You may need to select correct account.',
            );
          }
          await checkAccountUnread(account);
        }
      } catch (e) {
        debugPrint('checkAllAccountsOnce error for ${a.email}: $e');
      }
    }
  }

  void startPolling() {
    if (polling) return;
    polling = true;
    // first run immediately
    _pollNow();
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollNow());
    notifyListeners();
  }

  void stopPolling() {
    polling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    notifyListeners();
  }

  Future<void> _pollNow() async {
    for (final a in accounts) {
      // Try to sign in silently first; if the selected account doesn't match, user may need interactive sign-in
      try {
        GoogleSignInAccount? account = await googleSignIn.signInSilently();
        if (account == null || account.email != a.email) {
          // Try interactive sign in so user selects the correct account
          account = await googleSignIn.signIn();
        }
        if (account != null) {
          await checkAccountUnread(account);
        } else {
          debugPrint('No account available to check for ${a.email}');
        }
      } catch (e) {
        debugPrint('poll error for ${a.email}: $e');
      }
    }
  }

  void setPollInterval(Duration d) {
    pollInterval = d;
    if (polling) {
      stopPolling();
      startPolling();
    }
  }
}

/// Notification service (local)
class NotificationService {
  late FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin;

  Future<void> init() async {
    flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const initializationSettingsAndroid = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'gmail_notifier_channel',
      'Gmail Notifier',
      channelDescription: 'Thông báo email mới',
      importance: Importance.max,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(id, title, body, details);
  }
}

class MyApp extends StatelessWidget {
  final NotificationService notificationService;
  MyApp({required this.notificationService, Key? key}) : super(key: key);

  final storage = const FlutterSecureStorage();
  // configure scopes: readonly is enough for notifications; add other scopes if you want full content.
  final googleSignIn = GoogleSignIn(
    scopes: ['email', 'https://www.googleapis.com/auth/gmail.readonly'],
  );

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AccountProvider>(
          create:
              (_) => AccountProvider(
                storage: storage,
                googleSignIn: googleSignIn,
                notificationService: notificationService,
              ),
        ),
      ],
      child: MaterialApp(
        title: 'Gmail Notifier',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFEA4335), // Gmail red
            brightness: Brightness.light,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFEA4335),
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
            titleTextStyle: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
          cardTheme: CardTheme(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          listTileTheme: const ListTileThemeData(
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            minVerticalPadding: 8,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEA4335),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
            backgroundColor: Color(0xFFEA4335),
            foregroundColor: Colors.white,
            elevation: 4,
          ),
        ),
        home: HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

/// HomeScreen: manage accounts, start/stop polling, show list
class HomeScreen extends StatelessWidget {
  HomeScreen({Key? key}) : super(key: key);

  final List<Duration> presetIntervals = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AccountProvider>(context);
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.mail, size: 28),
            SizedBox(width: 12),
            Text('Gmail Notifier'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () async {
              await provider.checkAllAccountsOnce();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Đã kiểm tra lần nữa'),
                  backgroundColor: Colors.green[600],
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Polling Control Card
          Card(
            margin: EdgeInsets.all(16),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.schedule, color: Colors.grey[600]),
                      SizedBox(width: 8),
                      Text(
                        'Polling Status',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Status: ${provider.polling ? "Đang chạy" : "Dừng"}',
                              style: TextStyle(
                                color:
                                    provider.polling
                                        ? Colors.green[600]
                                        : Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Interval: ${provider.pollInterval.inSeconds}s',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ElevatedButton(
                            onPressed:
                                provider.polling
                                    ? provider.stopPolling
                                    : provider.startPolling,
                            child: Text(provider.polling ? 'Stop' : 'Start'),
                          ),
                          SizedBox(width: 8),
                          PopupMenuButton<Duration>(
                            onSelected: (d) => provider.setPollInterval(d),
                            itemBuilder:
                                (_) =>
                                    presetIntervals
                                        .map(
                                          (d) => PopupMenuItem(
                                            value: d,
                                            child: Text(
                                              '${d.inSeconds} seconds',
                                            ),
                                          ),
                                        )
                                        .toList(),
                            child: Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.grey[200],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(Icons.timer, color: Colors.grey[600]),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Accounts Section
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.account_circle, color: Colors.grey[600]),
                SizedBox(width: 8),
                Text(
                  'Gmail Accounts',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          SizedBox(height: 12),

          Expanded(
            child:
                provider.accounts.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.mail_outline,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Chưa có account nào',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[600],
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Thêm Gmail account để bắt đầu',
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      itemCount: provider.accounts.length,
                      itemBuilder: (_, idx) {
                        final a = provider.accounts[idx];
                        final unread = provider.lastUnreadCount[a.email] ?? 0;
                        return Card(
                          margin: EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFFEA4335),
                              child: Text(
                                a.email[0].toUpperCase(),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            title: Text(
                              a.email,
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              'Unread: $unread emails',
                              style: TextStyle(
                                color:
                                    unread > 0
                                        ? Colors.red[600]
                                        : Colors.grey[600],
                                fontWeight:
                                    unread > 0
                                        ? FontWeight.w500
                                        : FontWeight.normal,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.mail_outline,
                                    color: Colors.grey[600],
                                  ),
                                  onPressed: () async {
                                    // Try interactive sign-in to ensure correct account is selected
                                    try {
                                      final account =
                                          await provider.googleSignIn.signIn();
                                      if (account != null) {
                                        // fetch latest messages list and show simple dialog
                                        final auth =
                                            await account.authentication;
                                        final token = auth.accessToken;
                                        if (token == null) return;
                                        final resp = await http.get(
                                          Uri.parse(
                                            'https://gmail.googleapis.com/gmail/v1/users/me/messages?q=is:unread&maxResults=10',
                                          ),
                                          headers: {
                                            'Authorization': 'Bearer $token',
                                          },
                                        );
                                        if (resp.statusCode == 200) {
                                          final json = jsonDecode(resp.body);
                                          final msgs =
                                              json['messages']
                                                  as List<dynamic>?;
                                          if (msgs == null || msgs.isEmpty) {
                                            showDialog(
                                              context: context,
                                              builder:
                                                  (_) => AlertDialog(
                                                    title: Text('No unread'),
                                                    content: Text(
                                                      'Không có email chưa đọc',
                                                    ),
                                                  ),
                                            );
                                          } else {
                                            // fetch snippet for each message
                                            final buffer = StringBuffer();
                                            for (final m in msgs.take(10)) {
                                              final id = m['id'];
                                              final mresp = await http.get(
                                                Uri.parse(
                                                  'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=full',
                                                ),
                                                headers: {
                                                  'Authorization':
                                                      'Bearer $token',
                                                },
                                              );
                                              if (mresp.statusCode == 200) {
                                                final md = jsonDecode(
                                                  mresp.body,
                                                );
                                                final headers =
                                                    md['payload']['headers']
                                                        as List<dynamic>;
                                                final subjectHeader = headers
                                                    .firstWhere(
                                                      (h) =>
                                                          h['name'] ==
                                                          'Subject',
                                                      orElse: () => null,
                                                    );
                                                final fromHeader = headers
                                                    .firstWhere(
                                                      (h) =>
                                                          h['name'] == 'From',
                                                      orElse: () => null,
                                                    );
                                                final subject =
                                                    subjectHeader != null
                                                        ? subjectHeader['value']
                                                        : '(no subject)';
                                                final from =
                                                    fromHeader != null
                                                        ? fromHeader['value']
                                                        : '';
                                                final snippet =
                                                    md['snippet'] ?? '';
                                                buffer.writeln('From: $from');
                                                buffer.writeln(
                                                  'Subject: $subject',
                                                );
                                                buffer.writeln(
                                                  'Snippet: $snippet',
                                                );
                                                buffer.writeln('---');
                                              }
                                            }
                                            showDialog(
                                              context: context,
                                              builder:
                                                  (_) => AlertDialog(
                                                    title: Text(
                                                      'Unread (preview)',
                                                    ),
                                                    content:
                                                        SingleChildScrollView(
                                                          child: Text(
                                                            buffer.toString(),
                                                          ),
                                                        ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed:
                                                            () => Navigator.pop(
                                                              context,
                                                            ),
                                                        child: Text('Đóng'),
                                                      ),
                                                    ],
                                                  ),
                                            );
                                          }
                                        } else {
                                          showDialog(
                                            context: context,
                                            builder:
                                                (_) => AlertDialog(
                                                  title: Text('Error'),
                                                  content: Text(
                                                    'Gmail API lỗi: ${resp.statusCode} ${resp.body}',
                                                  ),
                                                ),
                                          );
                                        }
                                      }
                                    } catch (e) {
                                      debugPrint('view mails err: $e');
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: Colors.red[400],
                                  ),
                                  onPressed: () async {
                                    await provider.removeAccount(a);
                                  },
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => InboxScreen(account: a),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await provider.addAccount();
        },
        icon: Icon(Icons.add),
        label: Text('Add Account'),
        tooltip: 'Thêm Gmail account',
      ),
    );
  }
}

class _GmailMessagePreview {
  final String id;
  final String subject;
  final String from;
  final String snippet;
  _GmailMessagePreview({
    required this.id,
    required this.subject,
    required this.from,
    required this.snippet,
  });
}

/// Screen: show INBOX messages for a selected account
class InboxScreen extends StatefulWidget {
  final SavedAccount account;
  const InboxScreen({Key? key, required this.account}) : super(key: key);

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  bool loading = true;
  bool loadingMore = false;
  String? error;
  List<_GmailMessagePreview> messages = [];
  String? nextPageToken;
  static const int initialLoadCount = 20;
  static const int loadMoreCount = 10;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        messages.clear();
        nextPageToken = null;
        loading = true;
        error = null;
      });
    } else {
      setState(() {
        loading = true;
        error = null;
      });
    }

    try {
      final provider = context.read<AccountProvider>();
      // Ensure we have the correct Google account
      GoogleSignInAccount? gAccount =
          await provider.googleSignIn.signInSilently();
      if (gAccount == null || gAccount.email != widget.account.email) {
        gAccount = await provider.googleSignIn.signIn();
      }
      if (gAccount == null) {
        if (!mounted) return;
        setState(() {
          error = 'Không đăng nhập được tài khoản ${widget.account.email}';
          loading = false;
        });
        return;
      }

      final auth = await gAccount.authentication;
      final token = auth.accessToken;
      if (token == null) {
        if (!mounted) return;
        setState(() {
          error = 'Không lấy được token';
          loading = false;
        });
        return;
      }

      // 1) List messages in INBOX with pagination
      final queryParams = {
        'labelIds': 'INBOX',
        'maxResults': initialLoadCount.toString(),
      };
      if (nextPageToken != null && !refresh) {
        queryParams['pageToken'] = nextPageToken!;
      }

      final uri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages',
      ).replace(queryParameters: queryParams);

      final listResp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (listResp.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          error = 'Gmail API lỗi: ${listResp.statusCode} ${listResp.body}';
          loading = false;
        });
        return;
      }

      final listJson = jsonDecode(listResp.body) as Map<String, dynamic>;
      final items = (listJson['messages'] as List<dynamic>?) ?? [];
      nextPageToken = listJson['nextPageToken'] as String?;

      // 2) For each message id, fetch basic details with optimized API call
      final List<_GmailMessagePreview> loaded = [];
      for (final item in items) {
        final id = item['id'];

        // Use metadata format instead of full for faster loading
        final mResp = await http.get(
          Uri.parse(
            'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=metadata&metadataHeaders=Subject&metadataHeaders=From',
          ),
          headers: {'Authorization': 'Bearer $token'},
        );

        if (mResp.statusCode == 200) {
          final md = jsonDecode(mResp.body) as Map<String, dynamic>;
          final headers = (md['payload']?['headers'] as List<dynamic>?) ?? [];
          String subject = '(no subject)';
          String from = '';

          for (final h in headers) {
            if (h['name'] == 'Subject') {
              subject = (h['value'] ?? subject) as String;
            }
            if (h['name'] == 'From') {
              from = (h['value'] ?? from) as String;
            }
          }

          final snippet = (md['snippet'] ?? '') as String;
          loaded.add(
            _GmailMessagePreview(
              id: id,
              subject: subject,
              from: from,
              snippet: snippet,
            ),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        if (refresh) {
          messages = loaded;
        } else {
          messages.addAll(loaded);
        }
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (loadingMore || nextPageToken == null) return;

    setState(() {
      loadingMore = true;
    });

    try {
      final provider = context.read<AccountProvider>();
      GoogleSignInAccount? gAccount =
          await provider.googleSignIn.signInSilently();
      if (gAccount == null || gAccount.email != widget.account.email) {
        gAccount = await provider.googleSignIn.signIn();
      }
      if (gAccount == null) return;

      final auth = await gAccount.authentication;
      final token = auth.accessToken;
      if (token == null) return;

      // Load more messages
      final uri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages',
      ).replace(
        queryParameters: {
          'labelIds': 'INBOX',
          'maxResults': loadMoreCount.toString(),
          'pageToken': nextPageToken!,
        },
      );

      final listResp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (listResp.statusCode == 200) {
        final listJson = jsonDecode(listResp.body) as Map<String, dynamic>;
        final items = (listJson['messages'] as List<dynamic>?) ?? [];
        nextPageToken = listJson['nextPageToken'] as String?;

        // Fetch metadata for new messages
        final List<_GmailMessagePreview> loaded = [];
        for (final item in items) {
          final id = item['id'];

          final mResp = await http.get(
            Uri.parse(
              'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=metadata&metadataHeaders=Subject&metadataHeaders=From',
            ),
            headers: {'Authorization': 'Bearer $token'},
          );

          if (mResp.statusCode == 200) {
            final md = jsonDecode(mResp.body) as Map<String, dynamic>;
            final headers = (md['payload']?['headers'] as List<dynamic>?) ?? [];
            String subject = '(no subject)';
            String from = '';

            for (final h in headers) {
              if (h['name'] == 'Subject') {
                subject = (h['value'] ?? subject) as String;
              }
              if (h['name'] == 'From') {
                from = (h['value'] ?? from) as String;
              }
            }

            final snippet = (md['snippet'] ?? '') as String;
            loaded.add(
              _GmailMessagePreview(
                id: id,
                subject: subject,
                from: from,
                snippet: snippet,
              ),
            );
          }
        }

        if (!mounted) return;
        setState(() {
          messages.addAll(loaded);
          loadingMore = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          loadingMore = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingMore = false;
      });
      debugPrint('Error loading more: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.inbox, size: 24),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'INBOX - ${widget.account.email}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () => _load(refresh: true),
          ),
        ],
      ),
      body:
          loading
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        const Color(0xFFEA4335),
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Loading emails...',
                      style: TextStyle(color: Colors.grey[600], fontSize: 16),
                    ),
                  ],
                ),
              )
              : error != null
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: Colors.red[400]),
                    SizedBox(height: 16),
                    Text(
                      'Error',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.red[600],
                      ),
                    ),
                    SizedBox(height: 8),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => _load(refresh: true),
                      child: Text('Retry'),
                    ),
                  ],
                ),
              )
              : messages.isEmpty
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    SizedBox(height: 16),
                    Text(
                      'No emails in inbox',
                      style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Your inbox is empty',
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                  ],
                ),
              )
              : Column(
                children: [
                  // Email count indicator
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Colors.grey[100],
                    child: Row(
                      children: [
                        Icon(Icons.mail, size: 16, color: Colors.grey[600]),
                        SizedBox(width: 8),
                        Text(
                          '${messages.length} emails',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (nextPageToken != null) ...[
                          SizedBox(width: 16),
                          Text(
                            'Scroll to load more',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  Expanded(
                    child: ListView.separated(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      itemCount:
                          messages.length + (nextPageToken != null ? 1 : 0),
                      separatorBuilder:
                          (_, __) => Divider(height: 1, indent: 72),
                      itemBuilder: (_, i) {
                        if (i == messages.length) {
                          // Loading more indicator
                          if (nextPageToken != null) {
                            _loadMore(); // Trigger load more
                            return Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                child: Column(
                                  children: [
                                    CircularProgressIndicator(
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        const Color(0xFFEA4335),
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Loading more emails...',
                                      style: TextStyle(
                                        color: Colors.grey[600],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                          return SizedBox.shrink();
                        }

                        final m = messages[i];
                        return Container(
                          color: Colors.white,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFFEA4335),
                              child: Text(
                                m.from.isNotEmpty
                                    ? m.from[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            title: Text(
                              m.subject,
                              style: TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 15,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(height: 4),
                                Text(
                                  m.from,
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                SizedBox(height: 2),
                                Text(
                                  m.snippet,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 13,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                            isThreeLine: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder:
                                      (_) => EmailDetailScreen(
                                        account: widget.account,
                                        messageId: m.id,
                                      ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),

                  if (loadingMore)
                    Container(
                      padding: EdgeInsets.all(16),
                      color: Colors.grey[100],
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  const Color(0xFFEA4335),
                                ),
                                strokeWidth: 2,
                              ),
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Loading more emails...',
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
    );
  }
}

/// Screen: show full email content
class EmailDetailScreen extends StatefulWidget {
  final SavedAccount account;
  final String messageId;
  const EmailDetailScreen({
    Key? key,
    required this.account,
    required this.messageId,
  }) : super(key: key);

  @override
  State<EmailDetailScreen> createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends State<EmailDetailScreen> {
  bool loading = true;
  String? error;
  _EmailDetail? emailDetail;

  @override
  void initState() {
    super.initState();
    _loadEmail();
  }

  Future<void> _loadEmail() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final provider = context.read<AccountProvider>();
      // Ensure we have the correct Google account
      GoogleSignInAccount? gAccount =
          await provider.googleSignIn.signInSilently();
      if (gAccount == null || gAccount.email != widget.account.email) {
        gAccount = await provider.googleSignIn.signIn();
      }
      if (gAccount == null) {
        if (!mounted) return;
        setState(() {
          error = 'Không đăng nhập được tài khoản ${widget.account.email}';
          loading = false;
        });
        return;
      }

      final auth = await gAccount.authentication;
      final token = auth.accessToken;
      if (token == null) {
        if (!mounted) return;
        setState(() {
          error = 'Không lấy được token';
          loading = false;
        });
        return;
      }

      // Fetch full email content
      final resp = await http.get(
        Uri.parse(
          'https://gmail.googleapis.com/gmail/v1/users/me/messages/${widget.messageId}?format=full',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (resp.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          error = 'Gmail API lỗi: ${resp.statusCode} ${resp.body}';
          loading = false;
        });
        return;
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      debugPrint('Gmail API response: ${json.keys}');

      final payload = json['payload'] as Map<String, dynamic>?;
      if (payload == null) {
        if (!mounted) return;
        setState(() {
          error = 'Email không có nội dung';
          loading = false;
        });
        return;
      }

      // Extract headers
      final headers = (payload['headers'] as List<dynamic>?) ?? [];
      String subject = '(no subject)';
      String from = '';
      String to = '';
      String date = '';
      String cc = '';
      String bcc = '';

      for (final h in headers) {
        final name = (h['name'] as String?)?.toLowerCase() ?? '';
        final value = h['value'] ?? '';
        switch (name) {
          case 'subject':
            subject = value;
            break;
          case 'from':
            from = value;
            break;
          case 'to':
            to = value;
            break;
          case 'date':
            date = value;
            break;
          case 'cc':
            cc = value;
            break;
          case 'bcc':
            bcc = value;
            break;
        }
      }

      // Extract body content - improved logic
      String bodyText = '';
      String bodyHtml = '';

      // Helper function to extract text from a part
      String _extractTextFromPart(Map<String, dynamic> part) {
        if (part['body'] != null) {
          final body = part['body'] as Map<String, dynamic>;
          if (body['data'] != null) {
            try {
              final data = body['data'] as String;
              return utf8.decode(base64Url.decode(data));
            } catch (e) {
              debugPrint('Error decoding part data: $e');
              return '';
            }
          }
        }
        return '';
      }

      // Check if it's a simple message
      if (payload['body'] != null) {
        final body = payload['body'] as Map<String, dynamic>;
        final mimeType = body['mimeType'] as String? ?? '';
        debugPrint('Simple message mimeType: $mimeType');

        if (mimeType == 'text/plain') {
          bodyText = _extractTextFromPart(payload);
        } else if (mimeType == 'text/html') {
          bodyHtml = _extractTextFromPart(payload);
        }
      }

      // Check for multipart message
      if (payload['parts'] != null) {
        final parts = payload['parts'] as List<dynamic>;
        debugPrint('Multipart message with ${parts.length} parts');

        for (final part in parts) {
          final partData = part as Map<String, dynamic>;
          final mimeType = partData['mimeType'] as String? ?? '';
          debugPrint('Part mimeType: $mimeType');

          if (mimeType == 'text/plain' && bodyText.isEmpty) {
            bodyText = _extractTextFromPart(partData);
            debugPrint('Extracted plain text: ${bodyText.length} chars');
          } else if (mimeType == 'text/html' && bodyHtml.isEmpty) {
            bodyHtml = _extractTextFromPart(partData);
            debugPrint('Extracted HTML: ${bodyHtml.length} chars');
          }

          // Check for nested parts (multipart/alternative, multipart/mixed)
          if (partData['parts'] != null) {
            final nestedParts = partData['parts'] as List<dynamic>;
            for (final nestedPart in nestedParts) {
              final nestedData = nestedPart as Map<String, dynamic>;
              final nestedMimeType = nestedData['mimeType'] as String? ?? '';

              if (nestedMimeType == 'text/plain' && bodyText.isEmpty) {
                bodyText = _extractTextFromPart(nestedData);
                debugPrint(
                  'Extracted nested plain text: ${bodyText.length} chars',
                );
              } else if (nestedMimeType == 'text/html' && bodyHtml.isEmpty) {
                bodyHtml = _extractTextFromPart(nestedData);
                debugPrint('Extracted nested HTML: ${bodyHtml.length} chars');
              }
            }
          }
        }
      }

      // If still no content, try to get snippet
      if (bodyText.isEmpty && bodyHtml.isEmpty) {
        final snippet = json['snippet'] as String? ?? '';
        if (snippet.isNotEmpty) {
          bodyText = snippet;
          debugPrint('Using snippet as content: ${snippet.length} chars');
        }
      }

      debugPrint(
        'Final content - Text: ${bodyText.length} chars, HTML: ${bodyHtml.length} chars',
      );

      if (!mounted) return;
      setState(() {
        emailDetail = _EmailDetail(
          subject: subject,
          from: from,
          to: to,
          date: date,
          cc: cc,
          bcc: bcc,
          bodyText: bodyText,
          bodyHtml: bodyHtml,
        );
        loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Error loading email: $e');
      debugPrint('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        error = 'Lỗi: $e';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.email, size: 24),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Email Detail',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        actions: [IconButton(icon: Icon(Icons.refresh), onPressed: _loadEmail)],
      ),
      body:
          loading
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        const Color(0xFFEA4335),
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Loading email...',
                      style: TextStyle(color: Colors.grey[600], fontSize: 16),
                    ),
                  ],
                ),
              )
              : error != null
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: Colors.red[400]),
                    SizedBox(height: 16),
                    Text(
                      'Error',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.red[600],
                      ),
                    ),
                    SizedBox(height: 8),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(onPressed: _loadEmail, child: Text('Retry')),
                  ],
                ),
              )
              : emailDetail == null
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.email_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    SizedBox(height: 16),
                    Text(
                      'No email data',
                      style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                    ),
                  ],
                ),
              )
              : SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Email Header Card
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Subject
                            Row(
                              children: [
                                Icon(
                                  Icons.subject,
                                  color: const Color(0xFFEA4335),
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    emailDetail!.subject,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey[800],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 20),

                            // Email metadata
                            _buildInfoRow(
                              'From:',
                              emailDetail!.from,
                              Icons.person_outline,
                            ),
                            if (emailDetail!.to.isNotEmpty) ...[
                              SizedBox(height: 12),
                              _buildInfoRow(
                                'To:',
                                emailDetail!.to,
                                Icons.person,
                              ),
                            ],
                            if (emailDetail!.cc.isNotEmpty) ...[
                              SizedBox(height: 12),
                              _buildInfoRow('CC:', emailDetail!.cc, Icons.copy),
                            ],
                            if (emailDetail!.bcc.isNotEmpty) ...[
                              SizedBox(height: 12),
                              _buildInfoRow(
                                'BCC:',
                                emailDetail!.bcc,
                                Icons.visibility_off,
                              ),
                            ],
                            if (emailDetail!.date.isNotEmpty) ...[
                              SizedBox(height: 12),
                              _buildInfoRow(
                                'Date:',
                                emailDetail!.date,
                                Icons.schedule,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    SizedBox(height: 16),

                    // Email Content Card
                    Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.description,
                                  color: const Color(0xFFEA4335),
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Content',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey[800],
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 16),

                            // Body content
                            if (emailDetail!.bodyText.isNotEmpty) ...[
                              Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.grey[50],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: Text(
                                  emailDetail!.bodyText,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.5,
                                    color: Colors.grey[800],
                                  ),
                                ),
                              ),
                            ] else if (emailDetail!.bodyHtml.isNotEmpty) ...[
                              Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.grey[50],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.orange[100],
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'HTML Content',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.orange[800],
                                        ),
                                      ),
                                    ),
                                    SizedBox(height: 12),
                                    Text(
                                      emailDetail!.bodyHtml,
                                      style: TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: Colors.grey[800],
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else ...[
                              Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(32),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.inbox_outlined,
                                      size: 48,
                                      color: Colors.grey[400],
                                    ),
                                    SizedBox(height: 16),
                                    Text(
                                      'Không có nội dung email',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: Icon(icon, color: Colors.grey[600], size: 18),
        ),
        SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey[700],
              fontSize: 14,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontSize: 14, color: Colors.grey[800]),
          ),
        ),
      ],
    );
  }
}

class _EmailDetail {
  final String subject;
  final String from;
  final String to;
  final String date;
  final String cc;
  final String bcc;
  final String bodyText;
  final String bodyHtml;

  _EmailDetail({
    required this.subject,
    required this.from,
    required this.to,
    required this.date,
    required this.cc,
    required this.bcc,
    required this.bodyText,
    required this.bodyHtml,
  });
}
