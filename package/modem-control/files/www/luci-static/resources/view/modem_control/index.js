'use strict';
'require view';
'require ui';
'require rpc';
'require poll';

/*
 * Modem control.
 *
 * Everything here goes through the single `modem` ubus service - it owns the
 * QMI channel, so this page never has to worry about colliding with the
 * dashboard on the LCD or with a scan started from another browser tab.
 *
 * Applying is deliberately one round trip: mode, bands and operator go in a
 * single `set`, which means one disconnect instead of three, and the service
 * rolls everything back if the modem fails to register afterwards.
 */

var callStatus     = rpc.declare({ object: 'modem', method: 'status' });
var callConfig     = rpc.declare({ object: 'modem', method: 'config' });
var callSet        = rpc.declare({ object: 'modem', method: 'set',
                                   params: [ 'mode', 'bands', 'netsel', 'mcc', 'mnc', 'apn', 'profile' ] });
var callScan       = rpc.declare({ object: 'modem', method: 'scan' });
var callScanResult = rpc.declare({ object: 'modem', method: 'scan_result' });
var callReconnect  = rpc.declare({ object: 'modem', method: 'reconnect' });
var callApplyResult = rpc.declare({ object: 'modem', method: 'apply_result' });

var MODES = [
	[ 'lte',          _('Only 4G (LTE)') ],
	[ 'lte|umts',     _('4G + 3G') ],
	[ 'lte|umts|gsm', _('4G + 3G + 2G') ],
	[ 'all',          _('Any (automatic)') ]
];

function fmt(v, unit) {
	if (v === undefined || v === null || v === '')
		return '—';
	return unit ? v + ' ' + unit : v;
}

function signalClass(rssi) {
	var v = parseInt(rssi);
	if (isNaN(v)) return 'dim';
	if (v >= -75) return 'good';
	if (v >= -90) return 'warn';
	return 'bad';
}

return view.extend({
	cfg: {},
	scanning: false,
	applying: false,
	applyLabel: null,

	load: function() {
		return Promise.all([ callConfig(), callStatus() ]);
	},

	/* ------------------------------------------------------------ helpers */

	setBusy: function(on, text) {
		var box = document.getElementById('modem-busy');
		if (box) {
			box.style.display = on ? '' : 'none';
			box.textContent = text || '';
		}
		document.querySelectorAll('.modem-action').forEach(function(el) {
			el.disabled = !!on;
		});
	},

	apply: function(ev) {
		var self = this;
		var mode = document.getElementById('modem-mode').value;
		var apn = document.getElementById('modem-apn').value.trim();

		var bands = [];
		document.querySelectorAll('.modem-band:checked').forEach(function(el) {
			bands.push(el.value);
		});

		if (!bands.length) {
			ui.addNotification(null, E('p', _('Select at least one band - a modem with no bands enabled cannot register.')), 'warning');
			return;
		}

		var current = self.cfg.current_band;
		if (current && bands.indexOf(String(current)) < 0) {
			if (!confirm(_('Band %s is the one currently carrying the connection. Unchecking it will drop the link. Continue?').format(current)))
				return;
		}

		self.setBusy(true, _('Applying and waiting for registration, up to a minute…'));

		self.applying = true;
		callSet(mode, bands.join(','), '', '', '', apn, '').then(function(res) {
			if (res && res.error) {
				self.applying = false;
				self.setBusy(false);
				ui.addNotification(null, E('p', _('Failed: %s').format(res.error)), 'error');
			}
		});
	},

	pickOperator: function(mcc, mnc, name) {
		var self = this;
		if (!confirm(_('Switch to %s (%s-%s)? The connection will drop while the modem re-registers.').format(name || (mcc + '-' + mnc), mcc, mnc)))
			return;

		var label = name || (mcc + '-' + mnc);
		self.setBusy(true, _('Switching to %s…').format(label));

		self.applying = true;
		self.applyLabel = label;
		callSet('', '', 'manual', mcc, mnc, '', '').then(function(res) {
			if (res && res.error) {
				self.applying = false;
				self.setBusy(false);
				ui.addNotification(null, E('p', _('Could not switch to %s: %s').format(label, res.error)), 'error');
			}
		});
	},

	autoOperator: function() {
		var self = this;
		self.setBusy(true, _('Switching to automatic selection…'));
		self.applying = true;
		self.applyLabel = _('automatic selection');
		callSet('', '', 'automatic', '', '', '', '').then(function(res) {
			if (res && res.error) {
				self.applying = false;
				self.setBusy(false);
				ui.addNotification(null, E('p', _('Could not switch: %s').format(res.error)), 'error');
			}
		});
	},

	startScan: function() {
		var self = this;
		self.setBusy(true, _('Scanning for networks, this takes about a minute…'));
		self.scanning = true;

		callScan().then(function(res) {
			if (!res || !res.error)
				ui.addNotification(null, E('p', _('Scanning… the modem sweeps every band, this takes about a minute and the connection may drop meanwhile.')), 'info');
			if (res && res.error) {
				self.setBusy(false);
				self.scanning = false;
				ui.addNotification(null, E('p', _('Failed: %s').format(res.error)), 'error');
			}
		});
	},

	renderScan: function(list) {
		var self = this;
		var box = document.getElementById('modem-scan-results');
		if (!box) return;

		box.innerHTML = '';
		if (!list || !list.length) {
			box.appendChild(E('em', {}, _('No networks found yet.')));
			return;
		}

		var rows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Network')),
			E('th', { 'class': 'th' }, _('Code')),
			E('th', { 'class': 'th' }, _('Status')),
			E('th', { 'class': 'th' }, '')
		]) ];

		var LABEL = {
			current:   _('in use'),
			forbidden: _('forbidden'),
			available: _('available')
		};

		list.forEach(function(n) {
			var forbidden = (n.status === 'forbidden');
			var current   = (n.status === 'current');

			var action;
			if (current)
				action = E('em', {}, _('current'));
			else if (forbidden)
				/* The SIM is barred from this network - offering a button that
				 * can only end in registration-denied is worse than no button. */
				action = E('span', { 'style': 'opacity:.6' }, _('not allowed'));
			else
				action = E('button', {
					'class': 'cbi-button cbi-button-apply modem-action',
					'click': ui.createHandlerFn(self, 'pickOperator', n.mcc, n.mnc, n.name)
				}, _('Select'));

			rows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					n.name || '—',
					n.home ? E('span', { 'style': 'color:#3fb950; margin-left:.5em' }, _('(home)')) : ''
				]),
				E('td', { 'class': 'td' }, n.mcc + '-' + n.mnc),
				E('td', { 'class': 'td' }, LABEL[n.status] || n.status || '—'),
				E('td', { 'class': 'td' }, action)
			]));
		});

		box.appendChild(E('table', { 'class': 'table' }, rows));
	},

	refresh: function(force) {
		var self = this;
		return Promise.all([ callStatus(), callScanResult(), callApplyResult() ]).then(function(r) {
			var st = r[0] || {}, sc = r[1] || {}, ap = r[2] || {};

			if (self.applying && ap.state && ap.state !== 'running') {
				self.applying = false;
				self.setBusy(false);
				var what = self.applyLabel ? _('Switched to %s.').format(self.applyLabel) : _('Applied.');
				self.applyLabel = null;
				if (ap.state === 'error')
					ui.addNotification(null, E('p', _('Did not work: %s').format(ap.message || _('unknown error'))), 'error');
				else
					ui.addNotification(null, E('p', what), 'info');
			}

			if (st.busy)
				self.setBusy(true, st.busy === 'rollback'
					? _('Registration failed - restoring the previous settings…')
					: _('Modem is busy: %s').format(st.busy));
			else if (!self.scanning && !self.applying)
				self.setBusy(false);

			var set = function(id, val) {
				var el = document.getElementById(id);
				if (el) el.textContent = val;
			};

			set('st-operator', fmt(st.operator));
			set('st-reg', fmt(st.reg_state));
			set('st-tech', fmt(st.tech));
			set('st-rssi', fmt(st.rssi, 'dBm'));
			set('st-rsrp', fmt(st.rsrp, 'dBm'));
			set('st-rsrq', fmt(st.rsrq, 'dB'));
			set('st-snr', fmt(st.snr, 'dB'));
			set('st-band', fmt(st.band));
			set('st-cell', fmt(st.cell_id));
			set('st-temp', fmt(st.temperature, '°C'));

			var bar = document.getElementById('st-bar');
			if (bar) bar.className = 'modem-signal ' + signalClass(st.rssi);

			if (st.band) self.cfg.current_band = st.band;

			if (self.scanning && sc.state === 'done') {
				self.scanning = false;
				self.setBusy(false);
				self.renderScan(sc.networks);

				var n = (sc.networks || []).length;
				if (n)
					ui.addNotification(null, E('p', _('Scan finished: %d network(s) found.').format(n)), 'info');
				else
					ui.addNotification(null, E('p', _('Scan finished, but no networks were reported. Try again - a scan can come back empty while the modem is busy re-registering.')), 'warning');
			}
			else if (sc.state === 'done' && sc.networks && sc.networks.length &&
			         !document.querySelector('#modem-scan-results table')) {
				self.renderScan(sc.networks);
			}
		});
	},

	/* ------------------------------------------------------------- render */

	render: function(data) {
		var self = this;
		var cfg = data[0] || {};
		self.cfg = cfg;

		var supported = (cfg.bands_supported || '').split(',').filter(function(b) { return b !== ''; });
		var active = (cfg.bands || '').split(',').map(function(b) { return b.trim(); });

		var bandBoxes = supported.map(function(b) {
			return E('label', { 'style': 'margin-right:1.2em; white-space:nowrap' }, [
				E('input', {
					'type': 'checkbox',
					'class': 'modem-band',
					'value': b,
					'checked': active.indexOf(b) >= 0 ? '' : null
				}),
				' B' + b
			]);
		});

		if (!bandBoxes.length)
			bandBoxes = [ E('em', {}, _('The modem did not report any supported LTE bands.')) ];

		var modeSel = E('select', { 'id': 'modem-mode', 'class': 'cbi-input-select' },
			MODES.map(function(m) {
				return E('option', { 'value': m[0], 'selected': cfg.mode === m[0] ? '' : null }, m[1]);
			}));

		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Modem')),

			E('div', {
				'id': 'modem-busy',
				'class': 'alert-message warning',
				'style': 'display:none'
			}, ''),

			/* ---- status ---- */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'id': 'st-bar', 'class': 'modem-signal dim',
				           'style': 'height:6px;border-radius:3px;background:#666;margin-bottom:0.8em' }),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'width': '33%' }, _('Operator')),
						E('td', { 'class': 'td', 'id': 'st-operator' }, '—'),
						E('td', { 'class': 'td', 'width': '20%' }, _('Registration')),
						E('td', { 'class': 'td', 'id': 'st-reg' }, '—')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Technology')),
						E('td', { 'class': 'td', 'id': 'st-tech' }, '—'),
						E('td', { 'class': 'td' }, _('Band')),
						E('td', { 'class': 'td', 'id': 'st-band' }, '—')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, 'RSSI'),
						E('td', { 'class': 'td', 'id': 'st-rssi' }, '—'),
						E('td', { 'class': 'td' }, 'RSRP'),
						E('td', { 'class': 'td', 'id': 'st-rsrp' }, '—')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, 'RSRQ'),
						E('td', { 'class': 'td', 'id': 'st-rsrq' }, '—'),
						E('td', { 'class': 'td' }, 'SNR'),
						E('td', { 'class': 'td', 'id': 'st-snr' }, '—')
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, _('Cell ID')),
						E('td', { 'class': 'td', 'id': 'st-cell' }, '—'),
						E('td', { 'class': 'td' }, _('Temperature')),
						E('td', { 'class': 'td', 'id': 'st-temp' }, '—')
					])
				]),
				E('button', {
					'class': 'cbi-button modem-action',
					'click': ui.createHandlerFn(self, function() {
						self.setBusy(true, _('Reconnecting…'));
						return callReconnect().then(function() {
							self.setBusy(false);
							self.refresh(true);
						});
					})
				}, _('Reconnect'))
			]),

			/* ---- settings ---- */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Settings')),

				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Network mode')),
					E('div', { 'class': 'cbi-value-field' }, modeSel)
				]),

				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('LTE bands')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('div', {}, bandBoxes),
						E('div', { 'class': 'cbi-value-description' },
						  _('Only bands the radio actually supports are listed. Leaving one band checked restricts the modem to it.'))
					])
				]),

				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('APN')),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', { 'type': 'text', 'id': 'modem-apn',
						             'class': 'cbi-input-text', 'value': cfg.apn || '' })
					])
				]),

				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply modem-action',
						'click': ui.createHandlerFn(self, 'apply')
					}, _('Apply')),
					' ',
					E('span', { 'class': 'cbi-value-description' },
					  _('If the modem does not register within a minute, the previous settings are restored automatically.'))
				])
			]),

			/* ---- operator scan ---- */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Operators')),
				E('p', {}, [
					E('button', {
						'class': 'cbi-button modem-action',
						'click': ui.createHandlerFn(self, 'startScan')
					}, _('Scan for networks')),
					' ',
					E('button', {
						'class': 'cbi-button modem-action',
						'click': ui.createHandlerFn(self, 'autoOperator')
					}, _('Automatic selection'))
				]),
				E('div', { 'id': 'modem-scan-results' }, E('em', {}, _('Not scanned yet.')))
			])
		]);

		poll.add(function() { return self.refresh(); }, 5);

		return view;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
