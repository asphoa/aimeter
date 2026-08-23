#!/usr/bin/env python3
"""Regenerates Sources/AIMeter/L10n.swift.

To add a language: append its code to LANGS, add one string to every row below,
and extend the `Lang` enum in the emitted header (search for "case system").
Run:  python3 tools/gen_l10n.py
"""
import os

LANGS = ["en", "zh-Hant", "fr", "de"]

ROWS = [
    ('p.claude', 'Claude Code', 'Claude Code', 'Claude Code', 'Claude Code'),
    ('p.codex', 'Codex', 'Codex', 'Codex', 'Codex'),
    ('p.agy', 'Antigravity', 'Antigravity', 'Antigravity', 'Antigravity'),
    ('p.openrouter', 'OpenRouter', 'OpenRouter', 'OpenRouter', 'OpenRouter'),
    ('p.deepseek', 'DeepSeek', 'DeepSeek', 'DeepSeek', 'DeepSeek'),
    ('p.local', 'Local AI', '本地 AI', 'IA locale', 'Lokale KI'),
    ('p.generic', 'Other', '其他', 'Autres', 'Sonstige'),
    ('g.5h', '5-hour window', '5 小時窗', 'Fenêtre de 5 h', '5-Stunden-Fenster'),
    ('g.week', 'Weekly window', '週窗', 'Fenêtre hebdomadaire', 'Wochenfenster'),
    ('g.overage', 'Overage', '超額', 'Dépassement', 'Überschreitung'),
    ('g.quota', 'Quota', '配額', 'Quota', 'Kontingent'),
    ('g.balance', 'Balance %@', '餘額 %@', 'Solde %@', 'Guthaben %@'),
    ('g.modelmem', 'Model memory', '模型佔用記憶體', 'Mémoire des modèles', 'Modellspeicher'),
    ('g.window.min', '%d-minute window', '%d 分鐘窗', 'Fenêtre de %d min', '%d-Minuten-Fenster'),
    ('g.window.hour', '%d-hour window', '%d 小時窗', 'Fenêtre de %d h', '%d-Stunden-Fenster'),
    ('g.window.day', '%d-day window', '%d 天窗', 'Fenêtre de %d j', '%d-Tage-Fenster'),
    ('g.limit.main', 'Primary limit', '主限額', 'Limite principale', 'Primäres Limit'),
    ('g.limit.sec', 'Secondary limit', '次限額', 'Limite secondaire', 'Sekundäres Limit'),
    ('e.timeout.keychain', 'Timed out (was the keychain dialog left unanswered?)', '逾時（鑰匙圈授權對話框沒被按？）', 'Délai dépassé (la boîte de dialogue du trousseau est-elle restée sans réponse ?)', 'Zeitüberschreitung (Schlüsselbund-Dialog unbeantwortet?)'),
    ('e.notoken', 'Could not obtain an access token', '取不到 access token', 'Impossible d’obtenir un jeton d’accès', 'Kein Zugriffstoken erhalten'),
    ('e.conn', 'Connection failed: %@', '連線失敗：%@', 'Échec de la connexion : %@', 'Verbindung fehlgeschlagen: %@'),
    ('e.connplain', 'Connection failed', '連線失敗', 'Échec de la connexion', 'Verbindung fehlgeschlagen'),
    ('e.http', 'HTTP %@', 'HTTP %@', 'HTTP %@', 'HTTP %@'),
    ('e.http2', 'HTTP %@: %@', 'HTTP %@：%@', 'HTTP %@ : %@', 'HTTP %@: %@'),
    ('e.notfound', 'Cannot find %@', '找不到 %@', 'Introuvable : %@', 'Nicht gefunden: %@'),
    ('k.nottext', 'Keychain item is not text', '鑰匙圈內容不是文字', 'L’élément du trousseau n’est pas du texte', 'Schlüsselbund-Eintrag ist kein Text'),
    ('k.missing', 'Keychain item “%@” not found', '鑰匙圈裏找不到「%@」', 'Élément « %@ » introuvable dans le trousseau', 'Schlüsselbund-Eintrag „%@“ nicht gefunden'),
    ('k.denied', 'Keychain access denied — relaunch and choose “Always Allow”', '鑰匙圈授權被拒——重新啟動本程式並選「總是允許」', 'Accès au trousseau refusé — relancez et choisissez « Toujours autoriser »', 'Schlüsselbund-Zugriff verweigert — neu starten und „Immer erlauben“ wählen'),
    ('k.error', 'Keychain error %@: %@', '鑰匙圈錯誤 %@：%@', 'Erreur de trousseau %@ : %@', 'Schlüsselbund-Fehler %@: %@'),
    ('c.expired', 'Sign-in expired — run claude in a terminal to log in again', '登入已過期——在終端跑一次 claude 重新登入', 'Session expirée — relancez claude dans un terminal pour vous reconnecter', 'Anmeldung abgelaufen — claude im Terminal erneut ausführen'),
    ('c.noheaders', 'Response carried no anthropic-ratelimit headers', '回應裏沒有 anthropic-ratelimit 標頭', 'La réponse ne contient aucun en-tête anthropic-ratelimit', 'Antwort enthielt keine anthropic-ratelimit-Header'),
    ('c.status', 'Status: %@', '狀態：%@', 'État : %@', 'Status: %@'),
    ('x.nosnapshot', 'No quota snapshot in recent sessions', '近期 session 裏沒有額度快照', 'Aucun instantané de quota dans les sessions récentes', 'Kein Kontingent-Schnappschuss in aktuellen Sitzungen'),
    ('x.nopercent', 'Snapshot carries no percentage field', '快照裏沒有百分比欄位', 'L’instantané ne contient aucun pourcentage', 'Schnappschuss enthält kein Prozentfeld'),
    ('x.plan', 'Plan: %@', '方案：%@', 'Formule : %@', 'Tarif: %@'),
    ('x.credits.unl', 'Extra credits: unlimited', '額外點數：無限', 'Crédits supplémentaires : illimités', 'Zusätzliche Credits: unbegrenzt'),
    ('x.credits', 'Extra credits: %@', '額外點數：%@', 'Crédits supplémentaires : %@', 'Zusätzliche Credits: %@'),
    ('x.reached', '⚠️ Limit reached: %@', '⚠️ 已觸頂：%@', '⚠️ Limite atteinte : %@', '⚠️ Limit erreicht: %@'),
    ('a.nostate', 'No antigravity-cli state directory found', '找不到任何 antigravity-cli 狀態目錄', 'Aucun répertoire d’état antigravity-cli trouvé', 'Kein antigravity-cli-Statusverzeichnis gefunden'),
    ('a.nolog', 'agy log not found', '找不到 agy 日誌', 'Journal agy introuvable', 'agy-Protokoll nicht gefunden'),
    ('a.norecord', 'No quota record in the log', '日誌裏沒有配額紀錄', 'Aucune trace de quota dans le journal', 'Kein Kontingent-Eintrag im Protokoll'),
    ('a.403', 'Quota request refused: account verification required (403)', '配額查詢被拒：帳號待驗證（403）', 'Requête de quota refusée : vérification du compte requise (403)', 'Kontingentabfrage abgelehnt: Kontoverifizierung erforderlich (403)'),
    ('a.403b', 'agy cannot read its own quota either — not a fault of this app', 'agy 自己也讀不到額度，不是本程式的問題', 'agy ne peut pas lire son propre quota non plus — ce n’est pas un défaut de cette app', 'agy kann sein eigenes Kontingent ebenfalls nicht lesen — kein Fehler dieser App'),
    ('a.failed', 'Quota request failed (see cli.log)', '配額查詢失敗（見 cli.log）', 'Échec de la requête de quota (voir cli.log)', 'Kontingentabfrage fehlgeschlagen (siehe cli.log)'),
    ('a.silent', 'Last check raised no error, but the CLI logged no number', '上次查詢無錯誤，但 CLI 沒把數字寫進日誌', 'La dernière vérification n’a pas échoué, mais la CLI n’a consigné aucun chiffre', 'Letzte Prüfung ohne Fehler, aber die CLI hat keine Zahl protokolliert'),
    ('a.silent2', 'Press “Check now” to read the quota panel from the agy client itself (takes about half a minute)', '按「立即檢查」讓 agy 自己的面板把配額讀出來（約需半分鐘）', 'Appuyez sur « Vérifier maintenant » pour lire le panneau de quota du client agy (environ 30 s)', '„Jetzt prüfen“ liest das Kontingent aus dem agy-Client selbst (dauert etwa eine halbe Minute)'),
    ('a.direct.fail', 'Direct quota endpoint failed: %@', '直連配額端點失敗：%@', 'Échec du point de terminaison de quota : %@', 'Direkter Kontingent-Endpunkt fehlgeschlagen: %@'),
    ('a.unknown', 'Endpoint responded but the fields were not recognised', '端點有回應但欄位不認得', 'Le point de terminaison a répondu, champs non reconnus', 'Endpunkt antwortete, Felder nicht erkannt'),
    ('a.remaining', 'Remaining: %@', '剩餘：%@', 'Restant : %@', 'Verbleibend: %@'),
    ('o.nokeys', 'No API keys configured', '沒有設定 API 金鑰', 'Aucune clé API configurée', 'Keine API-Schlüssel konfiguriert'),
    ('o.unread', 'Could not read: %@', '讀不到：%@', 'Illisible : %@', 'Nicht lesbar: %@'),
    ('o.left', '%@ of %@', '%@ / %@', '%@ sur %@', '%@ von %@'),
    ('o.nocap', 'No cap · this week %@ · total %@', '無上限 · 本週 %@ · 累計 %@', 'Sans plafond · cette semaine %@ · total %@', 'Kein Limit · diese Woche %@ · gesamt %@'),
    ('o.weekly', 'weekly', '週', 'hebdomadaire', 'wöchentlich'),
    ('d.nokey', 'No DeepSeek key configured', '沒有設定 DeepSeek 金鑰', 'Aucune clé DeepSeek configurée', 'Kein DeepSeek-Schlüssel konfiguriert'),
    ('d.unread', 'Could not read the key (%@)', '讀不到金鑰（%@）', 'Impossible de lire la clé (%@)', 'Schlüssel nicht lesbar (%@)'),
    ('d.unavailable', '⚠️ Account unavailable (out of credit or suspended)', '⚠️ 帳戶不可用（餘額不足或被停用）', '⚠️ Compte indisponible (crédit épuisé ou suspendu)', '⚠️ Konto nicht verfügbar (kein Guthaben oder gesperrt)'),
    ('d.peak', '🔴 China time %@ — peak pricing, hold batches', '🔴 中國時間 %@ — 峰時計價，批次先緩', '🔴 Heure de Chine %@ — tarif de pointe, différez les lots', '🔴 China-Zeit %@ — Spitzentarif, Stapel zurückhalten'),
    ('d.offpeak', '🟢 China time %@ — off-peak pricing', '🟢 中國時間 %@ — 谷時計價', '🟢 Heure de Chine %@ — tarif creux', '🟢 China-Zeit %@ — Nebenzeittarif'),
    ('l.none', 'Ollama and LM Studio are not serving', 'Ollama / LM Studio 都沒在提供服務', 'Ollama et LM Studio ne répondent pas', 'Ollama und LM Studio laufen nicht'),
    ('l.ollama.idle', 'Ollama: running, no model loaded', 'Ollama：服務在跑，未載入模型', 'Ollama : en service, aucun modèle chargé', 'Ollama: läuft, kein Modell geladen'),
    ('l.ollama.count', 'Ollama: %d models installed', 'Ollama：本機共 %d 個模型', 'Ollama : %d modèles installés', 'Ollama: %d Modelle installiert'),
    ('l.lms.idle', 'LM Studio: server running, no model loaded', 'LM Studio：伺服器在跑，無已載入模型', 'LM Studio : serveur actif, aucun modèle chargé', 'LM Studio: Server läuft, kein Modell geladen'),
    ('l.unload', 'unloads %@', '%@卸載', 'déchargement %@', 'entlädt %@'),
    ('l.sysmem', 'System memory free: %@ of %@', '系統可用記憶體：%@ / %@', 'Mémoire système libre : %@ sur %@', 'Freier Systemspeicher: %@ von %@'),
    ('m.loading', 'Loading…', '讀取中…', 'Chargement…', 'Wird geladen…'),
    ('m.snapshot', 'snapshot · %@', '快照 · %@', 'instantané · %@', 'Schnappschuss · %@'),
    ('m.resets', 'resets %@', '%@重置', 'réinitialisation %@', 'Zurücksetzung %@'),
    ('m.updated', 'Updated %@ · every %ds', '更新於 %@ · 每 %d 秒', 'Mis à jour %@ · toutes les %d s', 'Aktualisiert %@ · alle %d s'),
    ('m.refresh', 'Refresh now', '立即刷新', 'Actualiser', 'Jetzt aktualisieren'),
    ('m.login', 'Start at login', '開機時自動啟動', 'Lancer à l’ouverture de session', 'Beim Anmelden starten'),
    ('m.accounts', 'Accounts…', '帳號…', 'Comptes…', 'Konten…'),
    ('m.language', 'Language', '語言', 'Langue', 'Sprache'),
    ('m.lang.system', 'Follow system', '跟隨系統', 'Suivre le système', 'Systemsprache'),
    ('m.debug', 'Open debug folder', '打開除錯資料夾', 'Ouvrir le dossier de débogage', 'Debug-Ordner öffnen'),
    ('m.quit', 'Quit', '結束', 'Quitter', 'Beenden'),
    ('m.interval', 'Refresh interval', '刷新間隔', 'Intervalle d’actualisation', 'Aktualisierungsintervall'),
    ('m.seconds', '%d seconds', '%d 秒', '%d secondes', '%d Sekunden'),
    ('m.minutes', '%d minutes', '%d 分鐘', '%d minutes', '%d Minuten'),
    ('m.onopen', 'Only when I open the menu', '只在點開選單時', 'Seulement à l’ouverture du menu', 'Nur beim Öffnen des Menüs'),
    ('t.in', 'in %@', '%@後', 'dans %@', 'in %@'),
    ('t.ago', '%@ ago', '%@前', 'il y a %@', 'vor %@'),
    ('t.now', 'just now', '剛剛', 'à l’instant', 'gerade eben'),
    ('m.loginfail', 'Could not change the login item', '設定開機啟動失敗', 'Impossible de modifier l’élément d’ouverture de session', 'Anmeldeobjekt konnte nicht geändert werden'),
    ('w.title', 'Accounts', '帳號', 'Comptes', 'Konten'),
    ('w.intro', 'Add the services you want on the meter. Nothing here is uploaded anywhere; keys stay on this Mac.', '把你想看的服務加進來。這裏的東西不會上傳到任何地方，金鑰只留在這台 Mac。', 'Ajoutez les services à surveiller. Rien n’est envoyé ailleurs ; les clés restent sur ce Mac.', 'Fügen Sie die gewünschten Dienste hinzu. Nichts wird hochgeladen; Schlüssel bleiben auf diesem Mac.'),
    ('w.add', 'Add account', '加入帳號', 'Ajouter un compte', 'Konto hinzufügen'),
    ('w.detect', 'Detect automatically', '自動偵測', 'Détection automatique', 'Automatisch erkennen'),
    ('w.remove', 'Remove', '移除', 'Supprimer', 'Entfernen'),
    ('w.test', 'Test', '測試', 'Tester', 'Testen'),
    ('w.close', 'Close', '關閉', 'Fermer', 'Schließen'),
    ('w.cancel', 'Cancel', '取消', 'Annuler', 'Abbrechen'),
    ('w.save', 'Save', '儲存', 'Enregistrer', 'Sichern'),
    ('w.service', 'Service', '服務', 'Service', 'Dienst'),
    ('w.name', 'Name', '名稱', 'Nom', 'Name'),
    ('w.nameph', 'e.g. Work account', '例如：工作帳號', 'p. ex. Compte pro', 'z. B. Arbeitskonto'),
    ('w.howauth', 'How should this account sign in?', '這個帳號怎麼登入？', 'Comment ce compte doit-il s’authentifier ?', 'Wie soll sich dieses Konto anmelden?'),
    ('w.auth.paste', 'Paste an API key', '貼上 API 金鑰', 'Coller une clé API', 'API-Schlüssel einfügen'),
    ('w.auth.file', 'Use a key file', '使用金鑰檔', 'Utiliser un fichier de clé', 'Schlüsseldatei verwenden'),
    ('w.auth.folder', 'Point at an account folder', '指定帳號資料夾', 'Indiquer un dossier de compte', 'Kontoordner angeben'),
    ('w.auth.keychain', 'Read from the keychain', '從鑰匙圈讀取', 'Lire depuis le trousseau', 'Aus dem Schlüsselbund lesen'),
    ('w.key', 'API key', 'API 金鑰', 'Clé API', 'API-Schlüssel'),
    ('w.keysaved', 'Stored in your keychain, never in the settings file.', '存進你的鑰匙圈，不會寫進設定檔。', 'Stockée dans votre trousseau, jamais dans le fichier de réglages.', 'Im Schlüsselbund gespeichert, nie in der Einstellungsdatei.'),
    ('w.choose', 'Choose…', '選擇…', 'Choisir…', 'Auswählen…'),
    ('w.folder', 'Account folder', '帳號資料夾', 'Dossier du compte', 'Kontoordner'),
    ('w.keyfile', 'Key file', '金鑰檔', 'Fichier de clé', 'Schlüsseldatei'),
    ('w.keychainsvc', 'Keychain item', '鑰匙圈項目', 'Élément du trousseau', 'Schlüsselbund-Eintrag'),
    ('w.baseurl', 'Base URL', '基礎網址', 'URL de base', 'Basis-URL'),
    ('w.balpath', 'Balance path', '餘額路徑', 'Chemin du solde', 'Guthaben-Pfad'),
    ('w.none', 'No accounts yet — press “Detect automatically” to find what is already on this Mac.', '還沒有任何帳號——按「自動偵測」找出這台 Mac 上已經有的。', 'Aucun compte — appuyez sur « Détection automatique » pour trouver ce qui existe déjà.', 'Noch keine Konten — „Automatisch erkennen“ findet, was bereits vorhanden ist.'),
    ('w.added', 'Added %d account(s)', '已加入 %d 個帳號', '%d compte(s) ajouté(s)', '%d Konto/Konten hinzugefügt'),
    ('w.nonew', 'Nothing new found', '沒有找到新的', 'Rien de nouveau', 'Nichts Neues gefunden'),
    ('w.folderhelp', 'Pick the folder that acts as HOME for this account — the one containing %@.', '選這個帳號當作 HOME 的資料夾——裏面要有 %@。', 'Choisissez le dossier servant de HOME à ce compte — celui contenant %@.', 'Wählen Sie den Ordner, der als HOME dient — er muss %@ enthalten.'),
    ('w.dup', 'An account with that name already exists for this service', '這個服務底下已經有同名帳號', 'Un compte de ce nom existe déjà pour ce service', 'Für diesen Dienst existiert bereits ein Konto mit diesem Namen'),
    ('w.needname', 'Give the account a name', '請給帳號取個名字', 'Donnez un nom au compte', 'Geben Sie dem Konto einen Namen'),
    ('w.needcred', 'Fill in the credential first', '請先填入憑證', 'Renseignez d’abord les identifiants', 'Bitte zuerst die Zugangsdaten angeben'),
    ('w.enabled', 'Shown', '顯示', 'Affiché', 'Angezeigt'),
    ('m.barcolour', 'Bar colours', '長條配色', 'Couleurs des barres', 'Balkenfarben'),
    ('m.barcolour.provider', 'By service (red = nearly spent)', '依服務別（紅色＝快用完）', 'Par service (rouge = presque épuisé)', 'Nach Dienst (rot = fast aufgebraucht)'),
    ('m.barcolour.window', 'By window (red 5h / blue weekly)', '依窗別（紅＝5小時／藍＝週）', 'Par fenêtre (rouge 5 h / bleu hebdo)', 'Nach Fenster (rot 5 Std. / blau Woche)'),
    ('m.icon', 'Menu bar icon', '選單列圖示', 'Icône de la barre des menus', 'Menüleisten-Symbol'),
    ('w.remove.confirm', 'Remove “%@”?', '要移除「%@」嗎？', 'Supprimer « %@ » ?', '„%@“ entfernen?'),
    ('w.remove.key', 'The API key you saved for this account will be deleted from your keychain. This cannot be undone.', '你為這個帳號儲存的 API 金鑰會從鑰匙圈裏刪除，無法復原。', 'La clé API enregistrée pour ce compte sera supprimée de votre trousseau. Action irréversible.', 'Der für dieses Konto gespeicherte API-Schlüssel wird aus dem Schlüsselbund gelöscht. Das lässt sich nicht rückgängig machen.'),
    ('w.remove.plain', 'It will disappear from the meter. Nothing else is deleted — the key file or folder it points at is left alone.', '它會從額度表上消失。其他東西都不會被刪——它指向的金鑰檔或資料夾原封不動。', 'Il disparaîtra du compteur. Rien d’autre n’est supprimé : le fichier ou dossier ciblé reste intact.', 'Es verschwindet aus der Anzeige. Sonst wird nichts gelöscht — die referenzierte Datei bzw. der Ordner bleibt unberührt.'),
    ('w.claudehint', 'macOS will ask for permission the first time — choose “Always Allow”.', 'macOS 第一次會跳出授權窗——請選「Always Allow」。', 'macOS demandera une autorisation la première fois — choisissez « Toujours autoriser ».', 'macOS fragt beim ersten Mal nach — wählen Sie „Immer erlauben“.'),
    ('e.nothttp', 'Not an HTTP response', '不是 HTTP 回應', 'Réponse non HTTP', 'Keine HTTP-Antwort'),
    ('e.needurl', 'Missing base URL or balance path', '缺少基礎網址或餘額路徑', 'URL de base ou chemin du solde manquant', 'Basis-URL oder Guthaben-Pfad fehlt'),
    ('w.menubar', 'Menu bar', '選單列', 'Barre des menus', 'Menüleiste'),
    ('w.menubar.intro', 'Choose up to five services to show as bars, top to bottom. Each bar splits in two: the 5-hour pool above, the weekly pool below.', '選最多五項顯示成長條，由上而下。每條線上下對切：上半是 5 小時池，下半是週池。', 'Choisissez jusqu’à cinq services à afficher, de haut en bas. Chaque barre se divise en deux : réserve de 5 h en haut, hebdomadaire en bas.', 'Wählen Sie bis zu fünf Dienste, von oben nach unten. Jeder Balken teilt sich: 5-Stunden-Kontingent oben, Wochenkontingent unten.'),
    ('w.empty', '(empty)', '（空）', '(vide)', '(leer)'),
    ('w.preview', 'Preview', '預覽', 'Aperçu', 'Vorschau'),
    ('w.moveup', 'Move up', '上移', 'Monter', 'Nach oben'),
    ('w.movedown', 'Move down', '下移', 'Descendre', 'Nach unten'),
    ('w.worstkey', 'worst key', '最吃緊的金鑰', 'clé la plus sollicitée', 'kritischster Schlüssel'),
    ('w.sources', 'Sources shown in the panel', '面板顯示哪些來源', 'Sources affichées dans le panneau', 'Im Panel angezeigte Quellen'),
    ('w.getkey', 'Get a key at %@', '到 %@ 取得金鑰', 'Obtenir une clé sur %@', 'Schlüssel unter %@ holen'),
    ('w.checkevery', 'Check every', '檢測間隔', 'Vérifier toutes les', 'Prüfintervall'),
    ('m.manualonly', 'Manual only', '只手動檢查', 'Manuel seulement', 'Nur manuell'),
    ('w.intervalhint', 'Services you rarely need can be set to manual, so nothing is polled on your behalf.', '不常看的服務可以設成只手動檢查，這樣不會有任何背景輪詢。', 'Les services rarement consultés peuvent passer en manuel : aucune interrogation en arrière-plan.', 'Selten benötigte Dienste können auf manuell gestellt werden — dann wird nichts im Hintergrund abgefragt.'),
    ('w.checknow', 'Check now', '立即檢查', 'Vérifier maintenant', 'Jetzt prüfen'),
    ('a.tui.hint', 'Press “Check now” to read the quota panel from the agy client itself (takes about half a minute)', '按「立即檢查」讓 agy 自己的面板把配額讀出來（約需半分鐘）', 'Appuyez sur « Vérifier maintenant » pour lire le panneau de quota du client agy (environ 30 s)', '„Jetzt prüfen“ liest das Kontingent aus dem agy-Client selbst (dauert etwa eine halbe Minute)'),
    ('a.tui.fail', 'Could not read the quota panel — is an agy session already running?', '讀不到配額面板——是不是已經有一個 agy 在跑？', 'Impossible de lire le panneau de quota — une session agy est-elle déjà ouverte ?', 'Kontingent-Panel nicht lesbar — läuft bereits eine agy-Sitzung?'),
    ('a.tui.nobin', 'agy command not found', '找不到 agy 指令', 'Commande agy introuvable', 'Befehl agy nicht gefunden'),
    ('g.gemini', 'Gemini %@', 'Gemini %@', 'Gemini %@', 'Gemini %@'),
    ('g.claudegpt', 'Claude/GPT %@', 'Claude／GPT %@', 'Claude/GPT %@', 'Claude/GPT %@'),
    ('g.5h.short', '5-hour', '5 小時', '5 h', '5 Std.'),
    ('g.week.short', 'weekly', '週', 'hebdo', 'Woche'),
]

HEADER = '''import Foundation

/// Localisation. Deliberately a plain table rather than .lproj bundles: the app
/// ships as a single self-contained binary and the language is switchable from
/// the menu at runtime, which resource bundles do not do without a relaunch.
///
/// Regenerate with `python3 tools/gen_l10n.py` after editing that script.
enum Lang: String, CaseIterable, Codable, Sendable {
    case system, en, zhHant = "zh-Hant", fr, de

    var displayName: String {
        switch self {
        case .system: return L.t("m.lang.system")
        case .en:     return "English"
        case .zhHant: return "\u7e41\u9ad4\u4e2d\u6587"
        case .fr:     return "Fran\u00e7ais"
        case .de:     return "Deutsch"
        }
    }

    /// What `system` resolves to, falling back to English for any locale this
    /// app has no table for.
    var resolved: Lang {
        guard self == .system else { return self }
        for code in Locale.preferredLanguages {
            let l = code.lowercased()
            if l.hasPrefix("zh") { return .zhHant }
            if l.hasPrefix("fr") { return .fr }
            if l.hasPrefix("de") { return .de }
            if l.hasPrefix("en") { return .en }
        }
        return .en
    }

    var localeIdentifier: String {
        switch resolved {
        case .zhHant: return "zh-Hant"
        case .fr: return "fr"
        case .de: return "de"
        default: return "en"
        }
    }
}

enum L {
    /// Set at launch and whenever the user picks a language from the menu.
    nonisolated(unsafe) static var current: Lang = .system

    static var locale: Locale { Locale(identifier: current.localeIdentifier) }

    static func t(_ key: String) -> String {
        guard let row = table[key] else { return key }
        switch current.resolved {
        case .zhHant: return row.1
        case .fr:     return row.2
        case .de:     return row.3
        default:      return row.0
        }
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    private static let table: [String: (String, String, String, String)] = [
'''

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

out = [HEADER]
for key, en, zh, fr, de in ROWS:
    out.append('        "%s": ("%s", "%s", "%s", "%s"),' % (key, esc(en), esc(zh), esc(fr), esc(de)))
out.append("    ]")
out.append("}")

path = os.path.join(os.path.dirname(__file__), "..", "Sources", "AIMeter", "L10n.swift")
with open(path, "w") as fh:
    fh.write("\n".join(out) + "\n")
print("wrote", len(ROWS), "keys x", len(LANGS), "languages")
