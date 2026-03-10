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

```bash
# Tuer l'instance en cours (si lancée)
pkill -x VoiceInk || true

# Copier dans /Applications
cp -R build_output/Export/VoiceInk.app /Applications/

# Lancer
open /Applications/VoiceInk.app
```

---

## 4. Résoudre les problèmes de permissions (procédure complète)

> **Utiliser cette procédure si :** l'app demande les permissions en boucle, crash au démarrage avec une erreur de signature, ou les permissions ne s'enregistrent pas après acceptation.

### Étape 1 — Fermer l'application

```bash
pkill -x VoiceInk || true
```

### Étape 2 — Réinitialiser TOUTES les permissions TCC

```bash
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk
```

### Étape 3 — Supprimer l'ancienne installation

```bash
sudo rm -rf /Applications/VoiceInk.app
```

### Étape 4 — Rebuilder proprement

```bash
bash build_release.sh
```

### Étape 5 — Réinstaller

```bash
cp -R build_output/Export/VoiceInk.app /Applications/
```

### Étape 6 — Lancer et accepter les permissions UNE SEULE FOIS

```bash
open /Applications/VoiceInk.app
```

macOS demandera les permissions (Micro, Screen Recording, Accessibilité). Les accepter **une par une**. Elles seront mémorisées durablement grâce à la signature ad-hoc stable.

> **Si l'app apparaît encore dans "Accessibilité" dans les Réglages Système :**
> Ouvre Réglages Système > Confidentialité > Accessibilité, sélectionne VoiceInk, clique **"-"** pour la supprimer, puis relance l'app.

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

| Symptôme                                                                     | Solution                                                                                               |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Crash au démarrage (`Library not loaded: whisper.framework`)                 | Les frameworks ne sont pas re-signés → relancer `build_release.sh` (le script re-signe)                |
| Boucle de permission (demande 5x)                                            | Procédure complète §4                                                                                  |
| Build échoue (`entitlements require signing with a development certificate`) | Vérifier que `project.pbxproj` pointe vers `VoiceInkLocal.entitlements` et non `VoiceInk.entitlements` |
| Push GitHub bloqué (`secret scanning`)                                       | Cliquer le lien fourni par GitHub pour autoriser le secret historique de l'upstream                    |
| `whisper.xcframework` introuvable                                            | Vérifier le lien symbolique : `ls -la whisper.xcframework` → doit pointer vers le bon chemin           |
