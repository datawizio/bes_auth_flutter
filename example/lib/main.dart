import 'package:bes_auth_flutter/bes_auth_flutter.dart';
import 'package:flutter/material.dart';

BesAuth besAuth = BesAuth(
  serviceUrl: "YOURE",
  redirectPath: "YOURE_REDIRECT_PATH",
  clientId: "YOURE_CLIENT_ID",
  clientSecret: "YOURE_CLIENT_SECRET",
);

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  BesSession? _session;

  void _handleAuthificate(BuildContext context) async {
    BesSession? nextSession = await besAuth.authenticate(context);
    setState(() => _session = nextSession);
  }

  void _handleLogout() async {
    if (_session != null) {
      await besAuth.logout(_session!);
    }
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BesAuth example app'),
      ),
      body: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            RaisedButton(
              child: Text("Authificate"),
              onPressed: () => _handleAuthificate(context),
            ),
            const SizedBox(
              width: 50,
            ),
            RaisedButton(
              child: Text("Logout"),
              onPressed: _handleLogout,
            ),
          ],
        ),
      ),
    );
  }
}
