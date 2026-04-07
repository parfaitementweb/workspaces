# ws — Workspace manager pour Laravel + Claude Code

Crée des workspaces isolés via `git worktree`, avec setup automatique de Laravel Herd, base de données, dépendances, et session Claude Code.

Inspiré par [Polyscope](https://getpolyscope.com/) et [laravel-herd-worktree](https://github.com/harris21/laravel-herd-worktree), sans dépendance à une app tierce.

## Installation

```bash
cp ws /usr/local/bin/ws
chmod +x /usr/local/bin/ws
```

## Prérequis

- **Git** (git worktree)
- **Laravel Herd** installé et dans le PATH
- **Composer** et **npm**
- **Claude Code** (`claude` dans le PATH)
- **gh** (optionnel, pour créer des PRs depuis `ws finish`)

## Usage

Depuis la racine d'un projet Laravel :

```bash
cd ~/Users/Sites/valet/mon-projet
```

### Créer un workspace

```bash
ws create feature/auth            # HTTP par défaut
ws create feature/auth --secure   # HTTPS (herd secure)
```

Ça fait tout automatiquement :
- Crée un git worktree dans `.worktrees/mon-projet-feature-auth/`
- Copie le `.env` du projet principal
- Met à jour `APP_URL`, `SESSION_DOMAIN`, `SANCTUM_STATEFUL_DOMAINS`, `SESSION_SECURE_COOKIE`
- Crée une base de données isolée (`mon_projet_feature_auth`)
- Lance `composer install` et `npm install`
- Linke avec Herd → `http(s)://mon-projet-feature-auth.test`
- Vérifie la config Vite (`host: 'localhost'`, `cors: true`)
- Vide les caches Laravel

### Lancer Claude Code dans un workspace

```bash
ws run feature/auth    # ouvre Claude Code dans le worktree
ws run                 # choix interactif si plusieurs workspaces
```

Depuis un worktree, `ws run` sans argument lance Claude Code directement là où tu es.

### Voir l'état des workspaces

```bash
ws status
```

```
mon-projet — Workspaces

  mon-projet-feature-auth  (feature/auth) ●  +3  ✓ DB  ✓ Herd  → https://mon-projet-feature-auth.test
  mon-projet-fix-header    (fix/header)      +1  ✓ DB  ✓ Herd  → http://mon-projet-fix-header.test
```

Le `●` jaune indique des changements non commités.

### Ouvrir le site dans le navigateur

```bash
ws preview feature/auth
ws preview                 # depuis un worktree
```

Détecte automatiquement si le site est en HTTP ou HTTPS.

### Terminer le travail

```bash
ws finish                  # workflow guidé
ws finish feature/auth     # workspace spécifique
```

Trois options :
1. **Créer une PR** — commit, push, `gh pr create` (recommandé)
2. **Merger localement** — `git merge --no-commit --no-ff` pour review
3. **Abandonner** — supprime tout

### Supprimer un workspace

```bash
ws destroy feature/auth
```

Supprime le worktree, la branche locale, la base de données, le lien Herd, et le certificat SSL si applicable.

## Nommage

Le site Herd utilise le format `projet-branche.test` pour éviter les conflits entre projets :

| Projet | Branche | Site Herd |
|---|---|---|
| `mon-app` | `feature/login` | `mon-app-feature-login.test` |
| `autre-app` | `feature/login` | `autre-app-feature-login.test` |

## Structure

```
mon-projet/
├── .worktrees/                          # ignoré par git
│   ├── mon-projet-feature-auth/         # worktree isolé
│   │   ├── .env                         # APP_URL, DB, session configurés
│   │   ├── vendor/                      # composer install dédié
│   │   └── node_modules/               # npm install dédié
│   └── mon-projet-fix-header/
├── app/
├── composer.json
└── ...
```

## Ce qui est configuré automatiquement dans le .env

| Variable | Valeur |
|---|---|
| `APP_URL` | `http(s)://projet-branche.test` |
| `DB_DATABASE` | `original_db_projet_branche` |
| `SESSION_DOMAIN` | `projet-branche.test` |
| `SANCTUM_STATEFUL_DOMAINS` | Domaine ajouté (si Sanctum détecté) |
| `SESSION_SECURE_COOKIE` | `true` si --secure, `false` sinon |

## Dépannage

### 401 sur les routes API
Le domaine du worktree n'est pas dans `SANCTUM_STATEFUL_DOMAINS`. Normalement configuré automatiquement. Vérifier avec `php artisan config:clear`.

### Cookies rejetés
`SESSION_DOMAIN` ne correspond pas au domaine Herd. Vérifier le `.env` du worktree.

### Page blanche / erreurs CORS
Vérifier que `vite.config.js` a `host: 'localhost'` et `cors: true`. Tuer les process Vite existants : `pkill -f "node.*vite"`.

### Mixed Content (HTTPS)
Si le site est sécurisé avec Herd, s'assurer que `APP_URL` est en `https://`. Utiliser `ws create <branch> --secure`.

### Assets qui ne chargent pas
```bash
pkill -f "node.*vite"
rm -f public/hot
npm run dev
```

### Migrations échouées
La DB du worktree n'existe peut-être pas. Vérifier `DB_DATABASE` dans le `.env` et créer la base manuellement si nécessaire.

## Licence

MIT
