# VoiceInk Pro — Guide de Build & Maintenance

> Guide de référence pour builder, maintenir et déboguer la version locale **VoiceInk Pro**.
> Ce fichier est pensé pour être joint à l'IA lors d'une prochaine session.

---

## 1. Contexte & Architecture

| Élément                 | Valeur                                           |
| ----------------------- | ------------------------------------------------ |
| **Bundle ID**           | `com.prakashjoshipax.VoiceInk`                   |
| **Branche locale**      | `feature/superwhisper-features`                  |
| **Dépôt perso**         | `origin` → `github.com/chabelbossa/VoiceInk-Pro` |
| **Dépôt upstream**      | `upstream` → `github.com/beingpax/VoiceInk`      |
| **Script de build**     | `build_release.sh` (à la racine)                 |
| **Entitlements locaux** | `VoiceInk/VoiceInkLocal.entitlements`            |

### Modifications permanentes (à préserver à chaque mise à jour)

1. **`VoiceInk/Services/LicenseManager.swift`** — L'appel `migrateFromUserDefaultsIfNeeded()` dans `init()` doit être **commenté** pour éviter un crash (pas de certificat Apple).
2. **`VoiceInk/VoiceInk.swift`** — Le bloc `#if LOCAL_BUILD` doit désactiver CloudKit (`cloudKitDatabase: .none`).
3. **`VoiceInk.xcodeproj/project.pbxproj`** — La configuration **Release** doit pointer vers `VoiceInk/VoiceInkLocal.entitlements` (pas `VoiceInk.entitlements`).
4. **`build_release.sh`** — Doit contenir la signature ad-hoc et la re-signature des frameworks (voir §2).

---

## 2. Builder l'application

```bash
bash build_release.sh
```

Le script effectue automatiquement :

- Clean + Archive Xcode (Release, avec flag `LOCAL_BUILD`)
- Signature ad-hoc (`codesign -s -`) de l'app et de tous les frameworks embarqués
- Suppression des attributs de quarantaine (`xattr -cr`)
- Export vers `./build_output/Export/VoiceInk.app` et `./VoiceInk.app`

### Checklist du `build_release.sh`

Le script doit impérativement contenir ces éléments :

```bash
CODE_SIGN_IDENTITY="-"
CODE_SIGNING_REQUIRED=NO
CODE_SIGNING_ALLOWED=YES
SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD'
```

Et après l'export, un bloc de re-signature :

```bash
xattr -cr "$EXPORT_PATH/$APP_NAME.app"
find "$EXPORT_PATH/$APP_NAME.app/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' item; do
    codesign --force --sign "-" --preserve-metadata=identifier,entitlements "$item"
done
codesign --force --sign "-" --preserve-metadata=identifier,entitlements "$EXPORT_PATH/$APP_NAME.app"
```

---

## 3. Installer l'application

Commande unique (tuer + installer + reset permissions + lancer) :

```bash
pkill -x VoiceInk || true && \
rm -rf /Applications/VoiceInk.app && \
cp -R build_output/Export/VoiceInk.app /Applications/ && \
tccutil reset Microphone com.prakashjoshipax.VoiceInk && \
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk && \
tccutil reset Accessibility com.prakashjoshipax.VoiceInk && \
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk && \
echo "✅ Installé." && \
open /Applications/VoiceInk.app
```

> Après le lancement, macOS va demander chaque permission — accepte-les **une par une** (voir §4 pour les détails par permission).

---

## 4. Résoudre les problèmes de permissions (procédure complète)

> **Utiliser cette procédure si :** l'app demande les permissions en boucle, crash au démarrage, ou les permissions ne s'enregistrent pas.

### Étape 1 — Reset TCC + Réinstallation propre

```bash
# Fermer l'app
pkill -x VoiceInk || true

# Reset toutes les permissions
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk

# Supprimer et réinstaller
rm -rf /Applications/VoiceInk.app
bash build_release.sh
cp -R build_output/Export/VoiceInk.app /Applications/
open /Applications/VoiceInk.app
```

### Étape 2 — Accorder les permissions dans l'app

Au premier lancement, l'app affiche un écran de setup avec 4 permissions :

#### 🎤 Microphone Access

- Clique le bouton dans l'app → macOS affiche une alerte → **Autoriser**.

#### ⌨️ Keyboard Shortcut

- Configure le raccourci clavier → aucune alerte système, se configure directement.

#### 🖥️ Screen Recording Access

1. Clique **"Request Permission"** dans l'app.
2. macOS ouvre **Réglages Système > Confidentialité > Enregistrement de l'écran**.
3. Active le toggle **VoiceInk**.
4. Clique **"Refresh"** (icône ↺) dans l'app pour vérifier.

#### ✋ Accessibility Access _(la plus problématique)_

1. Clique **"Open System Settings"** dans l'app.
2. macOS ouvre **Réglages Système > Confidentialité > Accessibilité**.
3. **Si VoiceInk apparaît grisée ou décochée :**
   - Clique sur **VoiceInk** pour la sélectionner.
   - Clique le bouton **"-"** (Moins) en bas pour la **supprimer complètement** de la liste.
4. **Ferme et relance l'app :**
   ```bash
   pkill -x VoiceInk && open /Applications/VoiceInk.app
   ```
5. L'app va redemander l'accès → une alerte système apparaît → clique **"Ouvrir les réglages"** → active le toggle.

> ⚠️ **Pourquoi ce comportement ?** Sans signature Apple officielle, macOS peut "bloquer" l'entrée dans la liste Accessibilité après une réinstallation. La supprimer manuellement puis relancer est la seule façon de forcer une nouvelle demande propre.

---

## 5. Mettre à jour depuis l'upstream (nouvelle version du développeur)

> **Prompt à envoyer à l'IA :** _"Nouvelle mise à jour dispo, applique le guide VOICEINK_PRO_GUIDE.md"_

### Étape 1 — Sauvegarder et récupérer

```bash
git stash save "Config Perso"
git fetch upstream
git merge upstream/main
git stash pop
```

### Étape 2 — Résoudre les conflits

| Fichier                | Action                                                                                   |
| ---------------------- | ---------------------------------------------------------------------------------------- |
| `project.pbxproj`      | Accepter upstream, puis **réappliquer** `VoiceInkLocal.entitlements` à la config Release |
| `VoiceInk.swift`       | Garder **ta version** (bloc `#if LOCAL_BUILD`)                                           |
| `LicenseManager.swift` | Garder **ta version** (`migrateFromUserDefaultsIfNeeded()` commenté)                     |
| Autres                 | Accepter upstream en général                                                             |

### Étape 3 — Vérifier les modifications permanentes (§1)

Vérifie chaque point de la liste en §1 avant de builder.

### Étape 4 — Builder, installer, reset permissions

Suivre les §2, §3, §4 dans l'ordre.

### Étape 5 — Sauvegarder sur ton dépôt

```bash
git add -A
git commit -m "chore: Merge upstream vX.X + config locale"
git push origin feature/superwhisper-features
```

---

## 6. Dépannage rapide

| Symptôme                                                     | Solution                                                                                                             |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Crash au démarrage (`Library not loaded: whisper.framework`) | Frameworks non re-signés → relancer `build_release.sh`                                                               |
| Boucle de permission (demande 5x)                            | Procédure complète §4                                                                                                |
| Accessibilité toujours ❌ malgré acceptation                 | Supprimer VoiceInk de la liste dans Réglages Système, puis relancer l'app (voir §4 Étape 2)                          |
| Screen Recording toujours ❌                                 | Reset TCC + relancer : `tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk && open /Applications/VoiceInk.app` |
| Build échoue (`entitlements require signing`)                | Vérifier que `project.pbxproj` → config Release → `VoiceInkLocal.entitlements`                                       |
| Push GitHub bloqué (`secret scanning`)                       | Cliquer le lien fourni par GitHub pour autoriser le secret historique upstream                                       |
| `whisper.xcframework` introuvable                            | `ls -la whisper.xcframework` → vérifier le lien symbolique                                                           |

---

## 7. Commandes rapides de référence

```bash
# Build complet
bash build_release.sh

# Installer + reset toutes les permissions + lancer
pkill -x VoiceInk || true && rm -rf /Applications/VoiceInk.app && cp -R build_output/Export/VoiceInk.app /Applications/ && tccutil reset Microphone com.prakashjoshipax.VoiceInk && tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk && tccutil reset Accessibility com.prakashjoshipax.VoiceInk && tccutil reset AppleEvents com.prakashjoshipax.VoiceInk && open /Applications/VoiceInk.app

# Reset Accessibilité seule (si bloquée)
tccutil reset Accessibility com.prakashjoshipax.VoiceInk && pkill -x VoiceInk; open /Applications/VoiceInk.app

# Reset Screen Recording seule
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk && pkill -x VoiceInk; open /Applications/VoiceInk.app
```
