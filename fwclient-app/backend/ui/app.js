/* 内网穿透 · fwclient 管理页面 */
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };
  var followTimer = null;
  var upgradeTimer = null;
  var TAB_KEY = 'fwclient.tab';

  function api(path, opts) {
    opts = opts || {};
    return fetch(path, {
      method: opts.method || 'GET',
      headers: opts.body ? { 'Content-Type': 'application/json' } : undefined,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      cache: 'no-store'
    }).then(function (r) {
      if (!r.ok) { throw new Error('HTTP ' + r.status); }
      return r.json();
    });
  }

  function noticeAt(id, msg, kind) {
    var el = $(id);
    if (!el) { return; }
    el.textContent = msg || '';
    el.className = 'hint' + (kind ? ' ' + kind : '');
  }

  function notice(msg, kind) { noticeAt('notice', msg, kind); }

  /* 连接配置在「应用配置」页，提示要写在该页自己的位置上 */
  function configNotice(msg, kind) { noticeAt('config-notice', msg, kind); }

  function setBusy(btn, busy) {
    if (!btn) { return; }
    btn.disabled = busy;
  }

  /* ---------------- Tab 切换 ---------------- */

  function selectTab(panelId) {
    var tabs = document.querySelectorAll('.tab');
    var i;
    for (i = 0; i < tabs.length; i++) {
      tabs[i].classList.toggle('active', tabs[i].getAttribute('data-panel') === panelId);
    }
    var panels = document.querySelectorAll('.panel');
    for (i = 0; i < panels.length; i++) {
      panels[i].hidden = panels[i].id !== panelId;
    }
    try { localStorage.setItem(TAB_KEY, panelId); } catch (e) { /* 隐私模式下忽略 */ }
  }

  function initTabs() {
    var tabs = document.querySelectorAll('.tab');
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].addEventListener('click', function () {
        selectTab(this.getAttribute('data-panel'));
      });
    }
    var saved = null;
    try { saved = localStorage.getItem(TAB_KEY); } catch (e) { saved = null; }
    if (saved && document.getElementById(saved)) { selectTab(saved); }
  }

  /* ---------------- 状态 ---------------- */

  function refreshStatus() {
    return api('/api/status').then(function (res) {
      if (res.code !== 0) { throw new Error(res.msg); }
      var d = res.data;
      $('v-running').textContent = d.running ? '运行中' : '未运行';
      $('v-pid').textContent = d.pid || '-';
      $('v-version').textContent = d.fwVersion || '-';
      $('v-gateway').textContent = d.gateway || '未配置';
      $('v-device').textContent = d.deviceId || '未生成';
      $('v-device').title = d.deviceId || '';
      $('v-logfile').textContent = d.logFile || '-';
      $('v-logfile').title = d.logFile || '';
      $('foot-text').textContent = d.appDisplay + ' · 管理后台 ' + d.appVersion +
        (d.binary ? ' · ' + d.binary : '');

      var dot = $('dot');
      dot.className = 'dot ' + (d.running ? 'on' : 'off');
      $('pill-text').textContent = d.running
        ? '运行中 · PID ' + d.pid
        : (d.stoppedByUser ? '已手动停止' : '未运行');

      $('btn-start').disabled = d.running;
      $('btn-stop').disabled = !d.running;
      $('btn-restart').disabled = !d.running;

      if (document.activeElement !== $('in-gateway')) { $('in-gateway').value = d.gateway || ''; }
      $('in-token').placeholder = d.hasToken
        ? '已保存：' + d.tokenMasked + '（留空表示不修改）'
        : 'tk_xxxxxxxx';
      $('in-autostart').checked = !!d.autoStart;
      $('in-autoreconn').checked = !!d.autoReconn;
      $('in-verifytls').checked = !d.insecure;

      if (d.lastError) {
        notice(d.lastError, 'err');
      } else if (!d.running && d.stoppedByUser) {
        notice('客户端已手动停止，不会被自动重连拉起；点「启动」恢复。', '');
      }
      return d;
    }).catch(function (e) {
      notice('读取状态失败：' + e.message, 'err');
      $('dot').className = 'dot off';
      $('pill-text').textContent = '通信异常';
    });
  }

  /* ---------------- 操作 ---------------- */

  function action(path, btn, okMsg, body) {
    setBusy(btn, true);
    notice('正在执行…');
    return api(path, { method: 'POST', body: body || {} }).then(function (res) {
      notice(res.msg || okMsg, res.code === 0 ? 'ok' : 'err');
      return refreshStatus();
    }).catch(function (e) {
      notice('操作失败：' + e.message, 'err');
    }).then(function () {
      setBusy(btn, false);
    });
  }

  function saveConfig(ev) {
    ev.preventDefault();
    var body = {
      gateway: $('in-gateway').value.trim(),
      token: $('in-token').value.trim(),
      verifyTls: $('in-verifytls').checked,
      autoStart: $('in-autostart').checked,
      autoReconn: $('in-autoreconn').checked
    };
    if (!body.gateway) { configNotice('请填写网关域名', 'err'); return; }
    setBusy($('btn-save'), true);
    configNotice('正在保存…');
    api('/api/config', { method: 'POST', body: body }).then(function (res) {
      configNotice(res.msg, res.code === 0 ? 'ok' : 'err');
      if (res.code === 0) { $('in-token').value = ''; }
      return refreshStatus();
    }).catch(function (e) {
      configNotice('保存失败：' + e.message, 'err');
    }).then(function () { setBusy($('btn-save'), false); });
  }

  /* ---------------- 日志 ---------------- */

  function refreshLogs() {
    var lines = $('sel-lines').value;
    return api('/api/logs?lines=' + lines).then(function (res) {
      if (res.code !== 0) { throw new Error(res.msg); }
      var d = res.data;
      var el = $('log-out');
      var atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 30;
      el.textContent = (d.lines && d.lines.length) ? d.lines.join('\n') : '（暂无日志）';
      if (atBottom) { el.scrollTop = el.scrollHeight; }
      $('log-meta').textContent = '文件：' + d.file + ' · 大小 ' + d.size +
        ' 字节 · 更新于 ' + d.updated;
    }).catch(function (e) {
      $('log-meta').textContent = '读取日志失败：' + e.message;
    });
  }

  function setFollow(on) {
    if (followTimer) { clearInterval(followTimer); followTimer = null; }
    if (on) { followTimer = setInterval(refreshLogs, 4000); }
  }

  /* ---------------- 升级 ---------------- */

  function pollUpgrade() {
    api('/api/upgrade/status').then(function (res) {
      if (res.code !== 0) { return; }
      var d = res.data;
      if (d.output && d.output.length) {
        // 升级过程不再单开输出窗口，把最后一行进度显示在状态提示里
        notice('升级中：' + d.output[d.output.length - 1]);
      }
      if (d.running) {
        setBusy($('btn-upgrade'), true);
      } else {
        setBusy($('btn-upgrade'), false);
        if (upgradeTimer) { clearInterval(upgradeTimer); upgradeTimer = null; }
        $('v-version').textContent = d.version || $('v-version').textContent;
        notice('升级流程结束，当前版本 ' + (d.version || '未知'), 'ok');
        refreshStatus();
      }
    });
  }

  function startUpgrade() {
    setBusy($('btn-upgrade'), true);
    api('/api/upgrade', { method: 'POST', body: {} }).then(function (res) {
      if (res.code !== 0) {
        setBusy($('btn-upgrade'), false);
        notice(res.msg, 'err');
        return;
      }
      notice('正在检查更新…');
      if (upgradeTimer) { clearInterval(upgradeTimer); }
      upgradeTimer = setInterval(pollUpgrade, 1500);
      pollUpgrade();
    }).catch(function (e) {
      setBusy($('btn-upgrade'), false);
      notice('升级请求失败：' + e.message, 'err');
    });
  }

  /* ---------------- 应用更新（GitHub Release） ---------------- */

  var appUpdateBusy = false;

  function appNotice(msg, kind) { noticeAt('app-update-notice', msg, kind); }

  function renderAppUpdate(d) {
    $('v-app-cur').textContent = d.current ? 'v' + d.current : '-';
    $('v-app-latest').textContent = d.latest ? 'v' + d.latest : '读取失败';
    $('v-app-date').textContent = d.publishedAt
      ? new Date(d.publishedAt).toLocaleString()
      : '-';

    var notes = $('app-notes');
    if (d.notes) {
      notes.textContent = d.notes.length > 4000 ? d.notes.slice(0, 4000) + '\n…' : d.notes;
      notes.hidden = false;
    } else {
      notes.hidden = true;
    }

    var link = $('app-release-link');
    if (d.releaseUrl) {
      link.href = d.releaseUrl;
      link.hidden = false;
    } else {
      link.hidden = true;
    }

    var btn = $('btn-app-upgrade');
    if (d.error) {
      btn.disabled = true;
      appNotice(d.error, 'err');
      return;
    }
    if (!d.hasUpdate) {
      btn.disabled = true;
      btn.textContent = '已是最新版本';
      appNotice('当前已是最新版本 v' + d.current, 'ok');
      return;
    }
    btn.disabled = false;
    // 系统里没有 appcenter-cli 时，只能下载后到应用中心手动安装
    btn.textContent = d.installable ? '一键升级' : '下载最新版';
    appNotice('发现新版本 v' + d.latest + '，点「' + btn.textContent + '」'
      + (d.installable ? '自动下载并安装。' : '下载；当前用户无安装权限，需要到应用中心手动安装。'));
  }

  function refreshAppUpdate(force) {
    return api('/api/app/update' + (force ? '?refresh=1' : '')).then(function (res) {
      if (res.data) { renderAppUpdate(res.data); }
      else if (res.code !== 0) { appNotice(res.msg, 'err'); }
    }).catch(function (e) {
      appNotice('检查更新失败：' + e.message, 'err');
    });
  }

  function startAppUpgrade() {
    if (appUpdateBusy) { return; }
    appUpdateBusy = true;
    setBusy($('btn-app-upgrade'), true);
    setBusy($('btn-app-check'), true);
    appNotice('正在下载最新应用包…');

    api('/api/app/download', { method: 'POST', body: {} }).then(function (res) {
      if (res.code !== 0) { throw new Error(res.msg); }
      appNotice(res.msg + '，正在安装…');
      return api('/api/app/install', { method: 'POST', body: {} });
    }).then(function (res) {
      if (res.code === 0) {
        appNotice(res.msg, 'ok');
        setTimeout(function () { location.reload(); }, 8000);
      } else {
        appNotice(res.msg, 'err');
      }
    }).catch(function (e) {
      appNotice('升级失败：' + e.message + '（可在应用中心手动安装已下载的包）', 'err');
    }).then(function () {
      appUpdateBusy = false;
      setBusy($('btn-app-check'), false);
      refreshAppUpdate(false);
    });
  }

  /* ---------------- 绑定 ---------------- */

  function bind() {
    $('btn-refresh').addEventListener('click', function () {
      refreshStatus().then(function () { notice('状态已刷新', 'ok'); });
    });
    $('btn-start').addEventListener('click', function () {
      action('/api/start', $('btn-start'), '客户端已启动');
    });
    $('btn-stop').addEventListener('click', function () {
      action('/api/stop', $('btn-stop'), '客户端已关闭');
    });
    $('btn-restart').addEventListener('click', function () {
      action('/api/restart', $('btn-restart'), '客户端已重启');
    });
    $('config-form').addEventListener('submit', saveConfig);

    $('btn-upgrade').addEventListener('click', startUpgrade);

    $('btn-app-check').addEventListener('click', function () {
      appNotice('正在查询 GitHub…');
      refreshAppUpdate(true);
    });
    $('btn-app-upgrade').addEventListener('click', startAppUpgrade);

    $('btn-logs-refresh').addEventListener('click', refreshLogs);
    $('sel-lines').addEventListener('change', refreshLogs);
    $('in-follow').addEventListener('change', function () {
      setFollow(this.checked);
      if (this.checked) { refreshLogs(); }
    });
    $('btn-logs-clear').addEventListener('click', function () {
      var btn = $('btn-logs-clear');
      setBusy(btn, true);
      api('/api/logs/clear', { method: 'POST', body: {} }).then(function (res) {
        notice(res.msg, res.code === 0 ? 'ok' : 'err');
        return refreshLogs();
      }).catch(function (e) {
        notice('清空失败：' + e.message, 'err');
      }).then(function () { setBusy(btn, false); });
    });

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { setFollow(false); }
      else if ($('in-follow').checked) { setFollow(true); refreshStatus(); }
    });
  }

  document.addEventListener('DOMContentLoaded', function () {
    initTabs();
    bind();
    refreshStatus();
    refreshLogs();
    setFollow($('in-follow').checked);
    refreshAppUpdate(false);
    // 宿主主题变化时无需处理：CSS 使用 prefers-color-scheme 自适应
  });
})();
