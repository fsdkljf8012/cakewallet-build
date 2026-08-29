import 'dart:convert';

import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/utils/proxy_wrapper.dart';

/// Reading a public address's real history off the chain.
///
/// Every explorer here is public and needs no key. What comes back is what the
/// chain already publishes about an address that anyone can look up, so this
/// asks for exactly what a block explorer shows and nothing more.
///
/// Nothing in here touches the wallet. It returns a plain result and the store
/// decides what to do with it, which keeps the network side testable and stops
/// a failed lookup from leaving half-applied state behind.
class LarpWatchEntry {
  const LarpWatchEntry({
    required this.id,
    required this.baseUnits,
    required this.incoming,
    required this.date,
    this.counterparty,
    this.feeBaseUnits,
    this.height,
  });

  final String id;

  /// Magnitude only. [incoming] carries the sign, which is how every other
  /// transaction in the app is shaped.
  final BigInt baseUnits;
  final bool incoming;
  final DateTime date;
  final String? counterparty;
  final BigInt? feeBaseUnits;
  final int? height;

  factory LarpWatchEntry.fromJson(Map<String, dynamic> j) => LarpWatchEntry(
        id: j['id'] as String? ?? '',
        baseUnits: BigInt.tryParse(j['amount'] as String? ?? '0') ?? BigInt.zero,
        incoming: j['in'] as bool? ?? false,
        date: DateTime.fromMillisecondsSinceEpoch(j['date'] as int? ?? 0),
        counterparty: j['peer'] as String?,
        feeBaseUnits: BigInt.tryParse(j['fee'] as String? ?? ''),
        height: j['height'] as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'amount': baseUnits.toString(),
        'in': incoming,
        'date': date.millisecondsSinceEpoch,
        'peer': counterparty,
        'fee': feeBaseUnits?.toString(),
        'height': height,
      };
}

class LarpWatchResult {
  const LarpWatchResult({required this.balanceBaseUnits, required this.entries});

  final BigInt balanceBaseUnits;
  final List<LarpWatchEntry> entries;
}

/// A lookup that could not be done, with wording meant for the modal.
class LarpWatchException implements Exception {
  const LarpWatchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LarpWatch {
  static const _limit = 50;

  /// BlockCypher covers the bitcoin-family chains under one response shape
  /// and serves them without a key.
  ///
  /// Blockchair was the obvious choice here and was tried first. It answers a
  /// shared or datacentre IP with "temporarily blacklisted" inside an HTTP
  /// 200, so a caller that only checks the status code reports an empty
  /// wallet instead of a failure -- which is a worse outcome than not
  /// supporting the chain at all.
  static const _blockcypher = <String, String>{
    'LTC': 'ltc',
    'DOGE': 'doge',
    'DASH': 'dash',
  };

  /// BlockCypher does not index these two, so they go through Blockchair and
  /// wear its rate limits. Its errors are read properly below, so a blocked
  /// lookup says so rather than looking like an empty address.
  static const _blockchair = <String, String>{
    'BCH': 'bitcoin-cash',
    'ZEC': 'zcash',
  };

  /// Blockscout runs the same v2 API on every chain it indexes, so one parser
  /// serves all of them -- only the host changes.
  static const _blockscout = <String, String>{
    'ETH': 'eth.blockscout.com',
  };

  static String _key(CryptoCurrency c) => c.title.toUpperCase();

  static bool supports(CryptoCurrency currency) {
    final k = _key(currency);
    return k == 'BTC' ||
        k == 'SOL' ||
        _blockcypher.containsKey(k) ||
        _blockchair.containsKey(k) ||
        _blockscout.containsKey(k);
  }

  static String get supportedLabel => 'BTC, LTC, DOGE, DASH, BCH, ZEC, ETH and SOL';

  /// Why an unsupported coin cannot be looked up.
  ///
  /// Monero is not a gap another explorer would fill: there is no public
  /// record tying an address to its transactions, which is the entire design
  /// of the chain. Saying so is more useful than a generic failure.
  static String unsupportedReason(CryptoCurrency currency) {
    switch (_key(currency)) {
      case 'XMR':
      case 'WOW':
        return 'Monero-style chains publish no address history at all, so there '
            'is nothing for any explorer to look up.';
      default:
        return '${currency.title} lookups are not wired up. Supported: $supportedLabel.';
    }
  }

  static Future<LarpWatchResult> fetch(CryptoCurrency currency, String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) throw const LarpWatchException('Enter an address');
    final k = _key(currency);

    if (k == 'BTC') return _bitcoin(trimmed);
    if (k == 'SOL') return _solana(trimmed);

    final coin = _blockcypher[k];
    if (coin != null) return _blockcypherAddress(coin, trimmed);

    final chain = _blockchair[k];
    if (chain != null) return _blockchairAddress(chain, trimmed);

    final host = _blockscout[k];
    if (host != null) return _blockscoutAddress(host, trimmed);

    throw LarpWatchException(unsupportedReason(currency));
  }

  // ---------------------------------------------------------------- helpers

  static Future<dynamic> _getJson(Uri uri) async {
    try {
      final response = await ProxyWrapper().get(
        clearnetUri: uri,
        headers: <String, String>{'Accept': 'application/json'},
      );
      if (response.statusCode == 404) {
        throw const LarpWatchException('That address has never been seen on this chain');
      }
      if (response.statusCode == 429) {
        throw const LarpWatchException('The explorer is rate limiting; try again in a minute');
      }
      if (response.statusCode >= 400) {
        throw LarpWatchException('The explorer returned ${response.statusCode}');
      }
      return json.decode(response.body);
    } on LarpWatchException {
      rethrow;
    } catch (_) {
      throw const LarpWatchException('Could not reach the explorer');
    }
  }

  static BigInt _big(dynamic v) {
    if (v == null) return BigInt.zero;
    if (v is int) return BigInt.from(v);
    if (v is BigInt) return v;
    if (v is double) return BigInt.from(v.round());
    return BigInt.tryParse(v.toString()) ?? BigInt.zero;
  }

  static DateTime _utc(String? raw) {
    if (raw == null || raw.isEmpty) return DateTime.now();
    // Blockchair sends "2024-05-01 12:00:00" with no zone marker, and it is
    // UTC. Parsed as local it would place every entry hours out.
    final normalised = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
    final stamped = normalised.endsWith('Z') || normalised.contains('+')
        ? normalised
        : '${normalised}Z';
    return (DateTime.tryParse(stamped) ?? DateTime.now()).toLocal();
  }

  // ---------------------------------------------------------------- bitcoin

  /// blockchain.com's own address endpoint.
  ///
  /// Its "result" field is the signed net effect of the transaction on this
  /// address, which is precisely what a history row shows -- no need to walk
  /// inputs and outputs to work out who paid whom.
  static Future<LarpWatchResult> _bitcoin(String address) async {
    final data = await _getJson(
      Uri.https('blockchain.info', '/rawaddr/$address', <String, String>{'limit': '$_limit'}),
    );
    if (data is! Map<String, dynamic>) {
      throw const LarpWatchException('Unexpected response from blockchain.com');
    }

    final entries = <LarpWatchEntry>[];
    for (final raw in (data['txs'] as List<dynamic>? ?? <dynamic>[])) {
      if (raw is! Map<String, dynamic>) continue;
      final net = _big(raw['result']);
      final incoming = net >= BigInt.zero;
      entries.add(LarpWatchEntry(
        id: raw['hash'] as String? ?? '',
        baseUnits: net.abs(),
        incoming: incoming,
        date: DateTime.fromMillisecondsSinceEpoch((raw['time'] as int? ?? 0) * 1000),
        counterparty: _bitcoinPeer(raw, address, incoming),
        feeBaseUnits: _big(raw['fee']),
        height: raw['block_height'] as int?,
      ));
    }

    return LarpWatchResult(balanceBaseUnits: _big(data['final_balance']), entries: entries);
  }

  /// The other side of a bitcoin transaction: for money coming in, whoever
  /// funded it; for money going out, the first output that is not change.
  static String? _bitcoinPeer(Map<String, dynamic> tx, String address, bool incoming) {
    if (incoming) {
      for (final input in (tx['inputs'] as List<dynamic>? ?? <dynamic>[])) {
        if (input is! Map<String, dynamic>) continue;
        final prev = input['prev_out'];
        if (prev is! Map<String, dynamic>) continue;
        final addr = prev['addr'] as String?;
        if (addr != null && addr.isNotEmpty && addr != address) return addr;
      }
      return null;
    }
    for (final out in (tx['out'] as List<dynamic>? ?? <dynamic>[])) {
      if (out is! Map<String, dynamic>) continue;
      final addr = out['addr'] as String?;
      if (addr != null && addr.isNotEmpty && addr != address) return addr;
    }
    return null;
  }

  // ------------------------------------------------------------ blockcypher

  /// BlockCypher's address summary.
  ///
  /// It answers with references rather than transactions: one row per output
  /// paid to the address and one per input spent from it, so a single
  /// transaction can appear more than once and neither row is the amount on
  /// its own. Summing them per hash -- outputs positive, inputs negative --
  /// gives the net movement, which is the figure a history row shows.
  static Future<LarpWatchResult> _blockcypherAddress(String coin, String address) async {
    final data = await _getJson(Uri.https(
      'api.blockcypher.com',
      '/v1/$coin/main/addrs/$address',
      // Refs, not transactions, so this has to be well above the number of
      // rows wanted.
      <String, String>{'limit': '200'},
    ));
    if (data is! Map<String, dynamic>) {
      throw const LarpWatchException('Unexpected response from BlockCypher');
    }
    final error = data['error'];
    if (error is String && error.isNotEmpty) throw LarpWatchException(error);

    // Insertion-ordered, and the refs arrive newest first, so the rows come
    // out in the order they will be shown.
    final nets = <String, BigInt>{};
    final heights = <String, int?>{};
    final dates = <String, DateTime>{};

    for (final raw in (data['txrefs'] as List<dynamic>? ?? <dynamic>[])) {
      if (raw is! Map<String, dynamic>) continue;
      final hash = raw['tx_hash'] as String?;
      if (hash == null || hash.isEmpty) continue;
      // tx_input_n of -1 marks the ref as an output paid to this address;
      // anything else means the address spent it.
      final received = (raw['tx_input_n'] as int? ?? -1) == -1;
      final value = _big(raw['value']);
      nets[hash] = (nets[hash] ?? BigInt.zero) + (received ? value : -value);
      heights.putIfAbsent(hash, () => raw['block_height'] as int?);
      dates.putIfAbsent(hash, () => _utc(raw['confirmed'] as String?));
    }

    final entries = <LarpWatchEntry>[];
    for (final hash in nets.keys) {
      if (entries.length >= _limit) break;
      final net = nets[hash]!;
      entries.add(LarpWatchEntry(
        id: hash,
        baseUnits: net.abs(),
        incoming: net >= BigInt.zero,
        date: dates[hash] ?? DateTime.now(),
        height: heights[hash],
      ));
    }

    return LarpWatchResult(balanceBaseUnits: _big(data['final_balance']), entries: entries);
  }

  // ------------------------------------------------------------- blockchair

  static Future<LarpWatchResult> _blockchairAddress(String chain, String address) async {
    final data = await _getJson(Uri.https(
      'api.blockchair.com',
      '/$chain/dashboards/address/$address',
      <String, String>{'limit': '$_limit', 'transaction_details': 'true'},
    ));
    if (data is! Map<String, dynamic>) {
      throw const LarpWatchException('Unexpected response from Blockchair');
    }
    // Blockchair reports refusals inside a 200: a null body and the reason in
    // context. Left unread that looks exactly like an address with no history,
    // so a rate limit would be shown as an empty wallet.
    final context = data['context'];
    if (context is Map<String, dynamic>) {
      final code = context['code'];
      final message = context['error'];
      if (code is int && code >= 400) {
        throw LarpWatchException(
            message is String && message.isNotEmpty ? message : 'Blockchair returned $code');
      }
    }
    final body = data['data'];
    if (body is! Map<String, dynamic> || body[address] == null) {
      throw const LarpWatchException('That address has never been seen on this chain');
    }
    final entry = body[address] as Map<String, dynamic>;
    final summary = entry['address'] as Map<String, dynamic>? ?? <String, dynamic>{};

    final entries = <LarpWatchEntry>[];
    for (final raw in (entry['transactions'] as List<dynamic>? ?? <dynamic>[])) {
      // Without transaction_details these come back as bare hash strings,
      // which carry no amount, so there would be nothing to show.
      if (raw is! Map<String, dynamic>) continue;
      final net = _big(raw['balance_change']);
      entries.add(LarpWatchEntry(
        id: raw['hash'] as String? ?? '',
        baseUnits: net.abs(),
        incoming: net >= BigInt.zero,
        date: _utc(raw['time'] as String?),
        height: raw['block_id'] as int?,
      ));
    }

    return LarpWatchResult(balanceBaseUnits: _big(summary['balance']), entries: entries);
  }

  // ------------------------------------------------------------- blockscout

  static Future<LarpWatchResult> _blockscoutAddress(String host, String address) async {
    final summary = await _getJson(Uri.https(host, '/api/v2/addresses/$address'));
    // No filter: Blockscout rejects every value this endpoint was expected to
    // take and returns "Invalid value for enum" in a 200, which reads as an
    // address with no transactions. Unfiltered already means both directions.
    final history = await _getJson(Uri.https(host, '/api/v2/addresses/$address/transactions'));
    if (summary is! Map<String, dynamic> || history is! Map<String, dynamic>) {
      throw const LarpWatchException('Unexpected response from Blockscout');
    }
    for (final body in <Map<String, dynamic>>[summary, history]) {
      final errors = body['errors'];
      if (errors is List && errors.isNotEmpty) {
        final first = errors.first;
        final detail = first is Map<String, dynamic> ? first['detail'] : null;
        throw LarpWatchException(
            detail is String ? detail : 'Blockscout rejected the request');
      }
    }

    final lower = address.toLowerCase();
    final entries = <LarpWatchEntry>[];
    for (final raw in (history['items'] as List<dynamic>? ?? <dynamic>[])) {
      if (raw is! Map<String, dynamic>) continue;
      if (entries.length >= _limit) break;
      final from = (raw['from'] as Map<String, dynamic>?)?['hash'] as String?;
      final to = (raw['to'] as Map<String, dynamic>?)?['hash'] as String?;
      final outgoing = (from ?? '').toLowerCase() == lower;
      entries.add(LarpWatchEntry(
        id: raw['hash'] as String? ?? '',
        baseUnits: _big(raw['value']),
        incoming: !outgoing,
        date: _utc(raw['timestamp'] as String?),
        counterparty: outgoing ? to : from,
        feeBaseUnits: _big((raw['fee'] as Map<String, dynamic>?)?['value']),
        height: raw['block_number'] as int?,
      ));
    }

    return LarpWatchResult(balanceBaseUnits: _big(summary['coin_balance']), entries: entries);
  }

  // ----------------------------------------------------------------- solana

  static const _solanaRpc = 'api.mainnet-beta.solana.com';

  static Future<List<dynamic>> _rpc(List<Map<String, dynamic>> calls) async {
    if (calls.isEmpty) return <dynamic>[];
    try {
      final response = await ProxyWrapper().post(
        clearnetUri: Uri.https(_solanaRpc, '/'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: json.encode(calls),
      );
      if (response.statusCode == 429) {
        throw const LarpWatchException('The Solana node is rate limiting; try again in a minute');
      }
      if (response.statusCode >= 400) {
        throw LarpWatchException('The Solana node returned ${response.statusCode}');
      }
      final decoded = json.decode(response.body);
      // A batch of one may still come back as a bare object.
      return decoded is List<dynamic> ? decoded : <dynamic>[decoded];
    } on LarpWatchException {
      rethrow;
    } catch (_) {
      throw const LarpWatchException('Could not reach the Solana node');
    }
  }

  static Map<String, dynamic> _call(int id, String method, List<dynamic> params) =>
      <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};

  /// Solana has no explorer that will hand over amounts in one request, so
  /// this does what an explorer does: list the signatures, then read the
  /// balance movement out of each transaction.
  ///
  /// Both rounds are JSON-RPC batches, so the whole lookup is two requests
  /// rather than one per transaction -- the public node will not tolerate
  /// twenty-five separate calls.
  static Future<LarpWatchResult> _solana(String address) async {
    // 25 rather than 50: every signature costs a getTransaction below, and
    // the public node is the one being asked.
    const signatureLimit = 25;

    final head = await _rpc(<Map<String, dynamic>>[
      _call(0, 'getBalance', <dynamic>[address]),
      _call(1, 'getSignaturesForAddress', <dynamic>[
        address,
        <String, dynamic>{'limit': signatureLimit},
      ]),
    ]);

    final byId = <int, Map<String, dynamic>>{};
    for (final r in head) {
      if (r is Map<String, dynamic> && r['id'] is int) byId[r['id'] as int] = r;
    }

    final balanceResult = byId[0]?['result'];
    if (balanceResult is! Map<String, dynamic>) {
      final message = (byId[0]?['error'] as Map<String, dynamic>?)?['message'];
      throw LarpWatchException(
          message is String ? message : 'That is not a valid Solana address');
    }
    final lamports = _big(balanceResult['value']);

    final signatures = <String>[];
    final slots = <String, int?>{};
    final times = <String, int?>{};
    for (final s in (byId[1]?['result'] as List<dynamic>? ?? <dynamic>[])) {
      if (s is! Map<String, dynamic>) continue;
      final sig = s['signature'] as String?;
      if (sig == null || sig.isEmpty) continue;
      signatures.add(sig);
      slots[sig] = s['slot'] as int?;
      times[sig] = s['blockTime'] as int?;
    }

    if (signatures.isEmpty) {
      return LarpWatchResult(balanceBaseUnits: lamports, entries: <LarpWatchEntry>[]);
    }

    final details = await _rpc(<Map<String, dynamic>>[
      for (var i = 0; i < signatures.length; i++)
        _call(i, 'getTransaction', <dynamic>[
          signatures[i],
          <String, dynamic>{
            'encoding': 'jsonParsed',
            // Versioned transactions are the norm now; without this the node
            // refuses them outright and half the history comes back empty.
            'maxSupportedTransactionVersion': 0,
          },
        ]),
    ]);

    final detailById = <int, dynamic>{};
    for (final r in details) {
      if (r is Map<String, dynamic> && r['id'] is int) detailById[r['id'] as int] = r['result'];
    }

    final entries = <LarpWatchEntry>[];
    for (var i = 0; i < signatures.length; i++) {
      final sig = signatures[i];
      final tx = detailById[i];
      final blockTime = times[sig];
      final date =
          blockTime != null ? DateTime.fromMillisecondsSinceEpoch(blockTime * 1000) : DateTime.now();

      var net = BigInt.zero;
      BigInt? fee;
      String? peer;
      if (tx is Map<String, dynamic>) {
        final meta = tx['meta'] as Map<String, dynamic>?;
        final message = (tx['transaction'] as Map<String, dynamic>?)?['message'];
        final keys =
            message is Map<String, dynamic> ? message['accountKeys'] as List<dynamic>? : null;
        if (meta != null && keys != null) {
          fee = _big(meta['fee']);
          final pre = meta['preBalances'] as List<dynamic>? ?? <dynamic>[];
          final post = meta['postBalances'] as List<dynamic>? ?? <dynamic>[];
          // The lamport delta on this account is the amount, fee included for
          // the payer -- which is what the chain actually moved.
          var biggestOpposite = BigInt.zero;
          for (var k = 0; k < keys.length && k < pre.length && k < post.length; k++) {
            final entry = keys[k];
            final pubkey = entry is Map<String, dynamic> ? entry['pubkey'] as String? : '$entry';
            final delta = _big(post[k]) - _big(pre[k]);
            if (pubkey == address) {
              net = delta;
            } else if (delta.abs() > biggestOpposite.abs()) {
              biggestOpposite = delta;
              peer = pubkey;
            }
          }
        }
      }

      entries.add(LarpWatchEntry(
        id: sig,
        baseUnits: net.abs(),
        incoming: net >= BigInt.zero,
        date: date,
        counterparty: peer,
        feeBaseUnits: fee,
        height: slots[sig],
      ));
    }

    return LarpWatchResult(balanceBaseUnits: lamports, entries: entries);
  }
}
