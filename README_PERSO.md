# Guide de Maintenance Personnel - VoiceInk

Ce fichier résume les étapes nécessaires pour maintenir ta version personnalisée de VoiceInk, notamment après une mise à jour du code (git pull) ou une réinstallation.

---

## 🚀 Compilation Rapide (Après un Git Pull)

Après avoir récupéré les mises à jour avec `git pull`, voici la procédure complète :

```bash
# 1. Compiler la version Release
bash build_release.sh

# 2. Installer dans /Applications
pkill -x VoiceInk 2>/dev/null
cp -R /Users/user/projects/VoiceInk/VoiceInk.app /Applications/

# 3. Lancer l'application
open /Applications/VoiceInk.app
```

**⚠️ IMPORTANT :** Après une nouvelle compilation, il faut souvent réinitialiser les permissions macOS (voir sections 2 et 3).

---

## 1. Gestion de la Licence ("Hack Pro")

Si tu mets à jour le dépôt (`git pull`), il est probable que les fichiers de vérification de licence soient écrasés. Voici les fichiers à vérifier/modifier :

### Fichier : `VoiceInk/Models/LicenseViewModel.swift`

Il faut forcer l'état de la licence à `.licensed`.

**Modifications à faire :**

- **Ligne 12** : `@Published private(set) var licenseState: LicenseState = .licensed`
- **`loadLicenseState()`** : Remplacer tout le contenu par `licenseState = .licensed`
- **`canUseApp`** : Retourner toujours `true`
- **`validateLicense()`** : Forcer le succès (`licenseState = .licensed`)
- **`startTrial()`** : Forcer `licenseState = .licensed`
- **`removeLicense()`** : Garder `licenseState = .licensed` à la fin

### Fichier : `VoiceInk/Services/LicenseManager.swift`

**Ligne 18** : Désactiver la migration dans `init()` :

```swift
private init() {
    // Migration disabled for local builds without Apple Developer certificate
    // migrateFromUserDefaultsIfNeeded()
}
```

### Fichier : `VoiceInk/Services/KeychainService.swift`

**Ligne 101-113** : Simplifier `baseQuery()` pour éviter les crashs sans signature :

```swift
private func baseQuery(forKey key: String, syncable: Bool) -> [String: Any] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key
        // Note: kSecUseDataProtectionKeychain et kSecAttrSynchronizable désactivés
    ]
    return query
}
```

### Fichier : `VoiceInk/VoiceInk.swift`

**Ligne 152** : Désactiver CloudKit pour le dictionnaire (cause de crash) :

```swift
cloudKitDatabase: .none  // Au lieu de .private("iCloud.com.prakashjoshipax.VoiceInk")
```

### Fichier : `VoiceInk/CursorPaster.swift`

Vérifier que `showNotification` utilise la bonne API (sans paramètre `message:`) :

```swift
NotificationManager.shared.showNotification(
    title: "...",
    type: .error
)
```

---

## 2. Problèmes d'Accessibilité (Collage automatique)

Si l'application transcrit bien mais ne colle pas le texte dans la zone de texte active :

### Réparation des Permissions (MacOS)

C'est le problème le plus fréquent. Même si la case semble cochée, macOS peut "perdre" la connexion avec l'app après un nouveau build.

1. Aller dans **Réglages Système** > **Confidentialité et sécurité** > **Accessibilité**.
2. Chercher **VoiceInk** dans la liste.
3. **IMPORTANT :** Ne pas juste décocher/recocher. Il faut sélectionner VoiceInk et cliquer sur le bouton **"-" (Moins)** pour le supprimer totalement.
4. Relancer VoiceInk.
5. macOS redemandera la permission (ou l'ajouter manuellement avec le "+").

---

## 3. Problème "Screen Recording" (Contexte écran)

Si VoiceInk n'arrive pas à capturer le contexte de l'écran (Enhancement échoue ou log "Screen capture failed"), c'est souvent parce que macOS a invalidé la permission silencieusement après un nouveau build (car la signature numérique de l'app change).

**Symptôme :** La case est cochée, mais l'app ne voit rien ou redemande la permission en boucle (5+ fois).

**Solution Définitive (Février 2026) :**
J'ai modifié le script de build pour utiliser une **signature locale (ad-hoc)** et un fichier d'entitlements simplifié (`VoiceInkLocal.entitlements`). Cela stabilise l'identité de l'application.

Si le problème persiste, force le reset complet des permissions :

```bash
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
```

Ensuite, lance l'application et accepte **une seule fois**.
**Solution 1 (La plus fiable) :**

1. Aller dans **Réglages Système** > **Confidentialité et sécurité** > **Enregistrement de l'écran**.
2. Sélectionner **VoiceInk**.
3. **IMPORTANT :** Cliquer sur le bouton **"-" (Moins)** pour le supprimer de la liste.
4. Quitter et relancer VoiceInk.
5. Au moment de capturer, macOS demandera la permission. Accepter et **redémarrer l'app** quand macOS le demande.

**Solution 2 (Terminal) :**
Si la solution 1 ne marche pas, forcer le reset via le terminal :

```bash
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
```

---

## 4. Compiler pour la Production

Pour utiliser l'application sur ta machine sans Xcode (en mode "Release"), utilise le script de build personnalisé :

**Commande :**

```bash
bash build_release.sh
```

L'application sera générée ici : `/Users/user/projects/VoiceInk/VoiceInk.app`.

**Pour installer dans /Applications :**

```bash
pkill -x VoiceInk 2>/dev/null
cp -R /Users/user/projects/VoiceInk/VoiceInk.app /Applications/
open /Applications/VoiceInk.app
```

### ⚠️ Limitations (sans certificat Apple Developer)

| Fonctionnalité                | État                            |
| ----------------------------- | ------------------------------- |
| Transcription                 | ✅ Fonctionne                   |
| AI Enhancement                | ✅ Fonctionne                   |
| Collage automatique           | ✅ Fonctionne                   |
| Mode Pro                      | ✅ Toujours activé              |
| Sync iCloud Dictionnaire      | ❌ Désactivé (local uniquement) |
| Sync Keychain entre appareils | ❌ Désactivé                    |

---

## 5. Workflow Git (Sauvegarde & Mise à jour)

Le projet est configuré avec deux sources (remotes) :

- **`upstream`** : Le dépôt original de Beingpax (pour les mises à jour).
- **`origin`** : Ton dépôt personnel `VoiceInk-Pro` (pour sauvegarder tes modifications).

### Pour RÉCUPÉRER les nouvelles versions du développeur

```bash
# Méthode 1 : Rebase (garde tes commits séparés)
git pull --rebase upstream main

# Méthode 2 : Merge (si rebase pose problème)
git fetch upstream
git merge upstream/main
```

_Si Git affiche un "CONFLICT", garde tes modifications locales pour les fichiers de licence._

### Pour SAUVEGARDER tes changements sur ton GitHub

Une fois que tout fonctionne, envoie tes modifications sur ton dépôt privé :

```bash
git push origin main
```

---

## 6. Checklist Après Mise à Jour

Après un `git pull`, vérifie ces points :

- [ ] `LicenseViewModel.swift` → Force `.licensed` partout
- [ ] `LicenseManager.swift` → Migration désactivée
- [ ] `KeychainService.swift` → Query simplifiée
- [ ] `VoiceInk.swift` → CloudKit désactivé (`.none`)
- [ ] `CursorPaster.swift` → API `showNotification` correcte
- [ ] Compilation avec `bash build_release.sh`
- [ ] Copie vers `/Applications`
- [ ] Réinitialisation permissions Accessibilité si nécessaire
- [ ] Réinitialisation permissions Screen Recording si nécessaire

---

_Ce document est maintenu par Antigravity pour t'aider dans ton projet perso. Dernière mise à jour : 19 janvier 2026._
