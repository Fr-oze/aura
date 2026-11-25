# Aura

L'encoche du Mac qui se transforme, et un halo qui respire avec ta musique.

Une seule surface : **l'encoche elle-même**. Une forme noire, continue avec l'encoche physique et collée au bord haut de l'écran, s'étire en « ailes » pour les infos courtes et descend en panneau pour les contenus riches. Coins concaves à la jonction avec le bord de l'écran, coins arrondis en bas, tout en morphing sur ressort. Une lueur colorée épouse le contour de la forme en direct.

- **Ailes** (compact) : volume (haut-parleur, mini-barre, %), luminosité (soleil, %), raccourcis (⌘C « Copié »…), musique en cours (pochette à gauche, mini égaliseur à droite), agent au travail (logo de la source, points), tâche finie (coche verte).
- **Panneau** (étendu) : notification d'une autre app (icône, nom, titre, extrait, clic = ouvre l'app), validation d'une commande d'agent (Autoriser / Refuser, `↩` / `esc` après un clic dessus), et panneau d'accueil au survol de l'encoche avec quatre onglets : Accueil (musique avec contrôles, sessions d'agents), Météo, Presse-papiers, Notifications.
- **Halo d'encoche** : bleu pour le volume, orange pour la luminosité et les validations, vert pour une tâche finie, couleur de l'icône de l'app pour une notification, couleur de la pochette pour la musique. Couleurs réglables.
- **Halo d'écran** (option) : lueur sur les 4 bords, pilotée par le son du Mac.

Ordre de priorité : validation agent > notification > panneau d'accueil (survol) > volume, luminosité, raccourci > agent terminé ou en attente > musique en cours > agent au travail > repos. Rien ne passe jamais devant une validation en attente.

Sur un écran sans encoche, Aura dessine une encoche virtuelle en haut au centre : invisible au repos, elle sort du bord de l'écran quand il y a quelque chose à montrer. Pour le panneau d'accueil, survole le bord haut de l'écran, au centre.

## Boring Notch fait doublon

Aura prend maintenant en charge elle-même le volume, la luminosité, la musique et le survol de l'encoche. Avec Boring Notch lancé en même temps, deux formes se superposent sur l'encoche. **Quitte Boring Notch** (et retire-le des éléments de connexion), ou coupe au minimum ses HUD de volume et de luminosité dans ses réglages.

Le HUD de macOS (la pastille de volume du système) reste affiché : Aura n'intercepte pas les touches, elle se contente de réagir.

## Prérequis

- Mac Apple silicon, macOS 14 ou plus.
- Les Command Line Tools (pas besoin de Xcode) :

```bash
xcode-select --install
```

## Installer

```bash
./build.sh --install --clean
```

Ça compile, assemble `Aura.app`, la signe en ad-hoc, la copie dans `~/Applications`, la lance, puis supprime `.build` pour libérer le disque. L'icône d'Aura apparaît dans la barre de menus.

Sans option, `./build.sh` laisse juste `Aura.app` dans le dossier.

### Garder les autorisations entre deux compilations

En signature ad-hoc, macOS voit une app différente à chaque compilation et oublie ce que tu as
coché (Accessibilité, Accès complet au disque, Enregistrement de l'écran). Pour que ça tienne,
crée une fois une identité de signature locale :

```bash
./build.sh --cert
```

Ça fabrique un certificat auto-signé « Aura Dev » dans ton trousseau de session (macOS peut
demander ton mot de passe). Les builds suivants l'utilisent automatiquement. Le premier build
signé change l'identité d'Aura : il faut réaccorder les autorisations une dernière fois, elles
tiennent ensuite. Si la création automatique échoue, le script affiche les étapes à faire dans
Trousseau d'accès.

### Autotest

```bash
./build.sh --test
```

Compile, puis vérifie la logique qui ne se voit pas à l'écran : les règles qui décident s'il faut
te demander avant une commande, et la lecture des fichiers d'agenda. Rien ne s'installe, aucune
fenêtre ne s'ouvre. Source : `Sources/Aura/App/SelfTest.swift`.

## Brancher les agents

Barre de menus > Aura > **Réglages…** > **Agents** > section **Hooks** : clique **Installer** pour chaque agent (ou **Tout installer**), puis redémarre l'agent.

Chaque fichier est sauvegardé avant modification (`settings.json.20261125-143000.bak` à côté de l'original) et Aura n'ajoute que ses propres entrées. **Désinstaller les hooks** retire uniquement ce qu'Aura a ajouté.

| Agent | Fichier modifié | Ce qu'Aura voit |
|---|---|---|
| Claude Code | `~/.claude/settings.json` (`hooks`) | travail, validation des commandes Bash, attente, fin |
| Cursor | `~/.cursor/hooks.json` | validation des commandes shell, fichiers modifiés, fin |
| Codex | `~/.codex/config.toml` (`notify`) | fin de tour uniquement |

À savoir :

- **Codex** : `notify` ne signale que la fin d'un tour. Pas de suivi du travail en cours ni de validation. Si tu as déjà un `notify`, Aura te le montre et demande avant de le remplacer (l'ancien est gardé en commentaire et remis à la désinstallation).
- **Claude Code** : Aura ajoute aussi un hook `PostToolUse`, pour que l'encoche repasse de « attend ta réponse » à « au travail » dès que tu as répondu dans le terminal. En mode `bypassPermissions`, Aura ne demande rien.
- **Cursor** : si Aura est fermée, le hook répond `ask` et Cursor affiche sa propre demande.
- Si Aura ne tourne pas, les hooks sortent tout de suite sans rien bloquer.

Le bouton **Tester** (Travail, Validation, Terminé, Erreur) simule chaque état sans agent. Réglages > **Encoche** a aussi ses boutons de test (volume, luminosité, notification, agent).

### Règles de validation

- **Commandes routinières** (`ls`, `git status`, `npm run build`…) : autorisées d'office.
- **Toujours demander** (`rm`, `git push`, `curl`, `sudo`…) : passent toujours par l'encoche.
- Une règle est un début de commande, ou une regex précédée de `re:` (ex. `re:^npm run \w+$`).
- Une commande composée (`a && b`, `a | b`) n'est autorisée d'office que si chaque partie est routinière. Une redirection vers un fichier ou un `$(...)` empêche l'autorisation d'office.
- Sans réponse dans le délai, Aura applique la décision par défaut (« demander dans l'agent » au départ).

## Encoche

Réglages > **Encoche**. Activée par défaut.

- **Ce qui anime l'encoche** : volume, luminosité, musique, agent au travail, raccourcis, notifications. Chaque type se coupe à part.
- **Volume** : suivi par CoreAudio (un abonnement aux changements de la sortie audio, pas de sondage, aucune autorisation). Marche pour les touches, le Centre de contrôle et les autres apps.
- **Luminosité** : déclenchée par les touches de luminosité, valeur lue via `DisplayServicesGetBrightness` (framework privé de macOS, chargé à l'exécution ; s'il manque, seule l'animation est montrée). macOS peut exiger Accessibilité ou Surveillance de l'entrée pour qu'Aura voie ces touches.
- **Musique** : Spotify et Musique, via AppleScript (titre, artiste, pochette, lecture / pause / suivant / précédent). Les deux apps préviennent Aura à chaque changement, le sondage de fond ne passe que toutes les 4 s et seulement si l'app tourne.
- **Survol** : rester ~0,3 s sur l'encoche ouvre le panneau d'accueil, sortir la souris le referme. Délai réglable.
- **Halo d'encoche** : il porte exactement le même contour que la forme noire et se transforme avec elle (même ressort, même instant). Il apparaît en fondu-gonflement, respire tant qu'un état dure, pulse pour une validation ou une notification, lance une onde qui part de l'encoche et longe la forme à chaque écho, et son intensité suit la valeur du volume ou de la luminosité. Avec le halo musical allumé, il reprend sa couleur sur le contour de l'encoche et son liseré s'allume sur les battements. Intensité et couleur par type d'événement réglables.
- **Afficher le contour** (diagnostic) : trace en rouge, d'un trait de 1 px, le contour exact utilisé par Aura (bord de l'écran pour le halo, forme de l'encoche). Les mesures lues sur l'écran (taille, marge haute, bandes à gauche et à droite de l'encoche) s'affichent dessous, et dans Console.app (filtre « Aura encoche »).

La fenêtre de l'encoche est transparente, à cadre fixe, au-dessus de la barre de menus. Elle ne capte la souris que lorsque le pointeur est sur la forme noire ; partout ailleurs les clics passent au travers.

## Météo

Réglages > **Météo**. Données [Open-Meteo](https://open-meteo.com), sans compte ni clé.

- Temps actuel, 7 prochaines heures, 4 jours. °C / km/h ou °F / mph.
- Villes favorites : recherche par nom (géocodage Open-Meteo), ajout, retrait, ordre.
- Rien n'est chargé en tâche de fond. La météo se met à jour à l'ouverture de l'onglet, au plus une fois toutes les 15 min par ville (bouton ↻ pour forcer).

Requêtes utilisées : `https://api.open-meteo.com/v1/forecast` (`current`, `hourly`, `daily`, `timezone=auto`, `forecast_days=4`, `forecast_hours=8`) et `https://geocoding-api.open-meteo.com/v1/search` (`name`, `count`, `language`). Tout est dans `Sources/Aura/Weather/WeatherService.swift`.

## Les agents te posent des questions

Un agent peut demander quelque chose et recevoir ta réponse **dans l'encoche**, sans que tu ouvres
son terminal. La commande est installée toute seule au lancement d'Aura, dans `~/.aura/bin/aura`.

```bash
~/.aura/bin/aura ask "On part sur quelle option ?" --choix "Refaire,Garder"
~/.aura/bin/aura ask "Quel nom pour la branche ?" --texte
~/.aura/bin/aura ask "Quel fichier je dois lire ?" --fichier
~/.aura/bin/aura ask "Je pousse ?" --choix "Oui,Non" --detail "3 commits sur main" --delai 300
```

La réponse sort sur la sortie standard. Code de retour : `0` réponse donnée, `1` annulé ou délai
dépassé, `2` Aura ne tourne pas. L'agent reste bloqué le temps que tu répondes.

L'agent doit **recopier ta réponse dans son message suivant**. Sans ça, ce que tu as choisi n'existe
que dans son terminal et ne laisse aucune trace dans ta conversation. C'est dans les consignes à
coller (Réglages > Agents).

- `--choix` : jusqu'à 5 boutons. Le premier est le bouton par défaut (touche `↩`).
- `--texte` : un champ de saisie ; `↩` envoie.
- `--fichier` : ouvre le sélecteur de fichiers de macOS, renvoie le chemin.
- `esc` annule : la commande sort en code 1, l'agent reprend la main.
- `--choix` et `--texte` se combinent : les boutons donnent les réponses prévues, le champ sert à
  répondre autre chose. `↩` envoie le texte, ou prend la première réponse si le champ est vide.
- Ne mets pas « Annuler » dans les choix : `esc` annule déjà, et la commande sort en code 1.
- Sans `--choix`, `--texte` ni `--fichier`, la question propose Oui / Non.
- Une validation de commande passe toujours devant une question ; une question passe devant tout
  le reste (notification, musique, agenda).

Pour que tes agents s'en servent, il faut l'écrire dans leurs consignes : un agent ne devine pas
qu'une commande existe. **Réglages > Agents > « Questions posées par tes agents » > Copier les
consignes pour l'agent**, puis colle le bloc dans le `CLAUDE.md`, l'`AGENTS.md` ou la règle Cursor
du projet. Le bouton **Tester** pose une vraie question dans l'encoche pour voir à quoi ça
ressemble. Mets `~/.aura/bin` dans ton `PATH` pour écrire simplement `aura ask …`.

Tout ce qu'il y a à faire côté agent est dans Réglages > Agents : installer les hooks (un bouton
par agent, chaque fichier sauvegardé avant modification) et coller ces consignes.

## Agenda

Réglages > **Agenda**. Coupé par défaut. Aura s'abonne à l'adresse iCal d'un calendrier et la lit :
pas de compte à connecter, aucune autorisation macOS, aucune écriture possible. Onglet Agenda du
panneau de l'encoche : les rendez-vous des 14 prochains jours, groupés par jour.

Brancher **Google Agenda** :

1. Ouvre Google Agenda dans un navigateur, sur ordinateur.
2. Colonne de gauche, passe la souris sur le calendrier voulu > les trois points > **Paramètres et partage**.
3. Descends jusqu'à **Intégrer l'agenda**.
4. Copie l'**adresse secrète au format iCal** (elle finit par `.ics`).
5. Réglages > Agenda d'Aura : un nom, l'adresse, **Ajouter**.

Cette adresse secrète donne accès au contenu du calendrier à qui l'a : ne la partage pas, ne la
mets pas dans un dépôt. Si elle fuite, le bouton « Réinitialiser » de la même page Google en crée
une nouvelle. Pour un calendrier déjà public, l'adresse publique au format iCal (juste au-dessus
chez Google) convient aussi. iCloud, Outlook ou un planning partagé marchent pareil : il suffit
d'une adresse en `.ics`, et les `webcal://` sont acceptées.

Rafraîchissement : à l'ouverture de l'onglet, au plus une fois par quart d'heure (bouton dans les
réglages pour forcer). Répétitions gérées : quotidienne, hebdomadaire (avec jours choisis),
mensuelle, annuelle, avec intervalle, fin de série et dates retirées.

## Minuteur

Réglages > **Agenda** > Minuteur. Onglet Minuteur du panneau de l'encoche : un compte à rebours
de travail puis de pause, qui enchaîne tout seul et annonce chaque changement dans l'encoche.
Le minuteur suit l'heure réelle, donc une mise en veille ne le décale pas. Trois rythmes d'un clic
(25/5, 50/10, 15/3) et le bilan du jour à droite : séries terminées et temps de travail cumulé,
gardés d'un lancement à l'autre, remis à zéro au changement de date.

## Boire de l'eau

Réglages > **Agenda** > Boire de l'eau. Une pastille « Bois un coup » dans l'encoche à intervalle
réglable (60 min par défaut, de 15 à 180), avec le numéro du verre du jour.

Rien ne sort quand tu n'es pas là : après 5 minutes sans toucher au clavier ni à la souris, le
compte à rebours repart à ton retour. Le temps d'inactivité vient de `CGEventSource`, pas d'une
surveillance du clavier : aucune autorisation, et Aura ne voit jamais ce que tu tapes.

## Batterie

Réglages > **Agenda** > Batterie. L'encoche prévient au branchement, au débranchement, quand la
charge est terminée, et aux seuils de 20 %, 10 % et 5 % sur batterie. Sous 10 %, le halo passe au
rouge. Pas de pourcentage affiché en permanence. Aucune autorisation : macOS réveille Aura à
chaque changement d'alimentation.

## Écho des raccourcis

Réglages > **Raccourcis**. Activé par défaut.

- **Copie sans autorisation** : Aura regarde le compteur du presse-papiers toutes les 0,4 s (aucune permission). Une copie affiche donc « Copié » avec l'aperçu même si Accessibilité n'est pas accordée, et même si tu copies par un menu. Si le clavier l'a déjà signalée, l'écho n'est pas doublé.
- **Les autres raccourcis** (⌘V, ⌘Z, ⌘S…) demandent Accessibilité. Si elle manque, l'encoche affiche après une copie un message « Autorise Aura dans Accessibilité » : un clic ouvre la bonne page de Réglages Système (une fois par lancement, trois fois au plus). Aura revérifie l'autorisation toutes les 3 s et relance l'écoute du clavier dès qu'elle est accordée ; si rien ne sort malgré tout, quitte et relance Aura.

- Raccourcis reconnus : ⌘C Copié, ⌘X Coupé, ⌘V Collé, ⌘Z Annulé, ⇧⌘Z Rétabli, ⌘S Enregistré, ⌘A Tout sélectionné, ⌘F Recherche, ⇧⌘3/4/5 Capture. Chacun se coupe à part. ⌘Tab est ignoré. Les lettres sont lues d'après ta disposition de clavier (AZERTY compris).
- L'encoche s'élargit : icône à gauche, libellé à droite (ou la miniature si tu as copié une image).
- Enchaîner les raccourcis remplace le contenu sans refermer l'encoche.
- Options : durée d'affichage, petit éclat du halo d'écran, clic discret.
- **Historique du presse-papiers** : les 20 derniers textes copiés avec ⌘C / ⌘X, en mémoire seulement (option pour les garder entre deux lancements, alors écrits en clair dans les préférences d'Aura). Onglet Presse-papiers du panneau de l'encoche, ou menu d'Aura : un clic recopie. Les contenus marqués `org.nspasteboard.ConcealedType` ou `TransientType` (gestionnaires de mots de passe) ne sont ni affichés ni gardés.

Limite connue : macOS peut intercepter ⇧⌘3/4/5 avant qu'Aura ne les voie. Si l'écho « Capture » ne sort pas, c'est ça.

## Notifications dans l'encoche

Réglages > **Notifications**. Coupé par défaut.

macOS n'a pas d'API publique pour lire les notifications des autres apps. Aura lit donc, en lecture seule, la base SQLite du Centre de notifications :

| macOS | Emplacement |
|---|---|
| 15 Sequoia, 26 Tahoe | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` |
| 14 Sonoma | `$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db` |

- Aura regarde la date de modification de `db` et `db-wal` toutes les 1,5 s. Si rien n'a bougé, elle ne fait rien d'autre. Sinon elle copie la base (un clone instantané sur APFS, supprimé juste après), l'ouvre avec `SQLITE_OPEN_READONLY` et ne lit que les lignes plus récentes que la dernière vue.
- La base de macOS n'est jamais modifiée. « Tout effacer » vide la liste d'Aura, pas le Centre de notifications.
- **Retard normal de quelques secondes** : macOS garde une notification en mémoire environ 5 s avant de l'écrire dans la base. L'encoche s'ouvre donc après la bannière.
- Apps **ignorées** (jamais affichées) et **prioritaires** (affichées deux fois plus longtemps, même en « Ne pas déranger » d'Aura), à choisir parmi les apps déjà vues.
- Base introuvable ou illisible : le réglage affiche pourquoi, le module reste inactif, rien ne plante.

Astuce : pour ne voir les notifs d'une app que dans l'encoche, va dans Réglages Système > Notifications > l'app, garde « Autoriser les notifications » et « Centre de notifications » activés, et décoche « Bureau » (sur macOS 14 : style d'alerte « Aucun »). La bannière disparaît, la notification reste enregistrée, Aura la voit. Si tu décoches aussi « Centre de notifications », macOS ne l'enregistre plus.

Schéma lu : table `record` (`rec_id`, `app_id`, `data` = plist binaire, `delivered_date` en secondes depuis 2001) jointe à `app` (`app_id`, `identifier`). Dans le plist : `app`, et `req` → `titl`, `subt`, `body`. Si Apple change ce format, tout est dans `Sources/Aura/Notices/NotificationWatcher.swift` (`NoticeDatabase`).

## Permissions

Aura ne demande une autorisation qu'au moment où tu actives le module qui en a besoin.

- **Accessibilité** (écho des raccourcis, et touches de luminosité si macOS ne les transmet pas sans) : macOS ne laisse une app voir les raccourcis tapés dans les autres apps que si elle est cochée dans Réglages Système > Confidentialité et sécurité > Accessibilité (« Surveillance de l'entrée » convient aussi). Aura ne regarde que la combinaison de touches (⌘C, ⌘V…), jamais le texte que tu tapes, et n'enregistre rien. Coche Aura, puis quitte et relance l'app.
- **Accès complet au disque** (notifications dans l'encoche seulement) : depuis macOS 15, la base du Centre de notifications est protégée, et c'est la seule autorisation qui permet de l'ouvrir. Elle donne techniquement accès à beaucoup plus : Aura n'ouvre que ce fichier-là, en lecture seule. Réglages Système > Confidentialité et sécurité > Accès complet au disque, ajoute ou coche Aura, puis quitte et relance l'app.

- **Enregistrement de l'écran et de l'audio système** (halo seulement) : macOS l'exige pour écouter le son du Mac. Rien n'est enregistré, seul le niveau sonore est analysé. Réglages > Halo affiche le bouton qui ouvre Réglages Système. Coche Aura, puis quitte et relance l'app. macOS affiche un indicateur de capture dans la barre de menus tant que le halo écoute.
- **Automatisation** (Spotify / Musique) : demandée la première fois qu'Aura lit le morceau en cours (encoche « musique » activée par défaut, ou mode de couleur « Pochette » du halo). Sans elle, pas de titre, de pochette ni de contrôles.
- **Réseau** : seulement pour la météo (Open-Meteo) et les pochettes Spotify. Aucune autorisation à donner.
- **Notifications** : seulement si tu actives l'option dans Réglages > Général.

## Dépannage

**Le halo ne suit pas les bords de l'écran.** La lueur était tracée autour d'un rectangle arrondi dont le rayon venait du réglage « Coins arrondis » : avec un rayon plus grand que celui de la dalle (le curseur montait à 60 pt), elle suivait un grand arc et laissait un triangle sombre dans chaque coin. Corrigé : le coin est toujours rempli jusqu'au vrai bord de l'écran, le rayon est limité à 24 pt, et un ancien réglage trop grand est ramené à 10 pt au premier lancement. Pour vérifier : Réglages > Encoche > « Afficher le contour » trace le contour utilisé en rouge. Console.app, filtre « Aura halo » : la ligne doit finir par « identiques ».

**Deux formes sur l'encoche.** Boring Notch tourne encore : quitte-le.

**Le volume marche mais pas la luminosité.** Les touches de luminosité ne sont visibles qu'avec Accessibilité ou Surveillance de l'entrée sur certaines versions de macOS : coche Aura dans l'une des deux listes, puis relance l'app.

**L'app plantait (exception « needs another Update Constraints in Window pass »).** Une vue SwiftUI servait de contenu direct à la fenêtre de l'ancienne pilule et la redimensionnait pendant le layout. Corrigé : la fenêtre de l'encoche a un cadre fixe, son contenu est une vue AppKit simple, la vue SwiftUI n'en est qu'une sous-vue (`sizingOptions = []`, marges de sécurité figées à zéro), et les changements de forme passent par les calques, jamais par le cadre de la fenêtre.

**L'écho ou les notifications ne marchent plus après un rebuild.** Même cause que pour le halo ci-dessous : la signature change, macOS oublie Accessibilité et Accès complet au disque. Retire Aura de la liste concernée (bouton `–`), relance, autorise à nouveau. Ou :

```bash
tccutil reset Accessibility com.maxlab.aura
tccutil reset SystemPolicyAllFiles com.maxlab.aura
```

**Le halo ne réagit plus après un rebuild.** La signature ad-hoc change à chaque compilation, donc macOS oublie l'autorisation. Dans Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran, retire Aura de la liste (bouton `–`), relance Aura et autorise à nouveau. En cas de blocage :

```bash
tccutil reset ScreenCapture com.maxlab.aura
```

**« Le port est déjà pris ».** Change le port dans Réglages > Agents (les hooks suivent tout seuls, via `~/.aura/config.sh`), ou trouve qui l'occupe :

```bash
lsof -nP -iTCP:47823 -sTCP:LISTEN
```

**Un hook ne remonte rien.** Vérifie d'abord que l'app répond :

```bash
curl -s http://127.0.0.1:47823/health
```

Puis envoie un événement à la main, les ailes de l'encoche doivent s'ouvrir :

```bash
curl -s -X POST http://127.0.0.1:47823/event \
  -H 'Content-Type: application/json' \
  -d '{"source":"claude","session":"test","cwd":"/tmp/demo","event":"working","title":"Test","detail":"coucou"}'
```

Et une validation (la commande reste en attente jusqu'à ton clic) :

```bash
curl -s -X POST http://127.0.0.1:47823/approve \
  -H 'Content-Type: application/json' \
  -d '{"source":"claude","session":"test","cwd":"/tmp/demo","command":"git push origin main"}'
```

Si ces commandes marchent mais pas l'agent : vérifie que le hook est marqué « installé » dans Réglages > Agents, que tu as redémarré l'agent, et teste le script seul :

```bash
echo '{"hook_event_name":"Stop","session_id":"t","cwd":"/tmp/demo"}' | ~/.aura/hook.sh claude Stop
```

Valeurs acceptées pour `event` : `working`, `waiting`, `done`, `error`, `end`.

**L'installateur refuse un fichier.** Il ne touche pas à un JSON invalide (commentaires, virgule en trop). Corrige le fichier puis recommence.

## Formats des hooks

Vérifiés le 25 novembre 2026 sur la documentation officielle :

- Claude Code : https://code.claude.com/docs/en/hooks
  Entrée JSON sur stdin (`session_id`, `cwd`, `hook_event_name`, `tool_input.command`…), sortie `hookSpecificOutput.permissionDecision` = `allow` / `deny` / `ask`.
- Codex : https://developers.openai.com/codex/config-advanced (redirige vers https://learn.chatgpt.com/docs/config-file/config-advanced)
  `notify = ["programme", …]` à la racine de `config.toml`, JSON passé en dernier argument (`type`, `thread-id`, `cwd`, `last-assistant-message`).
- Cursor : https://cursor.com/docs/agent/hooks
  `hooks.json` version 1, entrée JSON sur stdin (`conversation_id`, `workspace_roots`, `command`…), sortie `permission` = `allow` / `deny` / `ask`.

Si un format change : les sorties attendues par les agents sont dans `Resources/hook.sh` (fonctions `claude_decision` et `cursor_permission`), la lecture des entrées dans `Sources/Aura/Agents/HookPayload.swift`.

## Structure

```
build.sh
Resources/        Info.plist, hook.sh, aura (commande `aura ask`)
Sources/Aura/
  App/            AuraApp, AppState, Feedback, SelfTest
  Agents/         EventServer, HookPayload, AgentStore, ApprovalRules, HookInstaller, CodexWatcher
  Notch/          NotchEngine (scènes, priorités, souris), NotchSurface (fenêtre, calques, morphing),
                  NotchShape (contour), NotchModels, NotchViews (ailes, panneaux), NotchHome (onglets),
                  NotchIndicators (égaliseur, points), NotchExtras (agenda, minuteur)
  Weather/        WeatherService (Open-Meteo)
  Agenda/         CalendarService, ICSParser (abonnements iCal)
  Focus/          Pomodoro (minuteur), WaterReminder (rappel de boire)
  Power/          BatteryWatcher
  Echo/           ShortcutEcho (raccourcis, volume, luminosité)
  Notices/        NotificationWatcher
  Halo/           OverlayController, GlowView, AudioEngine, BeatDetector, NowPlaying, ColorExtractor
  Settings/       SettingsStore, SettingsView, NotchPanes, ReactionPanes, AgendaPane, MenuView
```
