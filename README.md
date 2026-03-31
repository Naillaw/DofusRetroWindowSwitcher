# DofusRetroWindowSwitcher

Script de rotation entre plusieurs fenêtres Dofus Retro sous Linux.

Le script :
- détecte les fenêtres dont le titre contient `Dofus Retro`
- associe chaque fenêtre à un pseudo via son titre, par exemple `Nayl - Dofus Retro v1.47.22`
- trie les comptes par initiative décroissante
- active la fenêtre suivante à chaque exécution
- synchronise le son lors des mises à jour de configuration pour ne le garder que sur la fenêtre avec la plus haute initiative

## Fichiers

- `switcher.sh` : script principal
- `dofus_accounts.conf.dist` : exemple de configuration
- `dofus_accounts.conf` : configuration locale ignorée par git

## Configuration

Créer `dofus_accounts.conf` à côté du script en partant de `dofus_accounts.conf.dist`.

Format :

```text
# Format : pseudo:initiative
# Sections supportees : [ACTIVE] et [HISTORICAL]

[ACTIVE]
Pseudo:Initiative

[HISTORICAL]
Pseudo:Initiative
```

Exemple :

```text
[ACTIVE]
Nayl:100
Nayl-Sacri:90

[HISTORICAL]
Nayl-Eni:80
Nayl-Panda:70
```

Le script :
- ne cycle que sur les comptes de `[ACTIVE]`
- conserve les initiatives de `[HISTORICAL]` pendant le scan
- ignore les lignes vides et les commentaires commençant par `#`

## Dépendances

Le script utilise :
- `wmctrl`
- `xprop`
- `pactl`

## Utilisation

Lancer le script :

```bash
/home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh
```

Ou :

```bash
bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh
```

Le switch simple n’ajuste plus l’audio, ce qui réduit le délai au changement de fenêtre.

Scanner les fenêtres ouvertes et mettre à jour automatiquement `dofus_accounts.conf` :

```bash
bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh --scan-config
```

Le scan :
- détecte les fenêtres `Dofus Retro` ouvertes
- extrait les pseudos depuis leurs titres
- met les fenêtres ouvertes dans `[ACTIVE]`
- déplace les anciens comptes absents dans `[HISTORICAL]`
- conserve les initiatives déjà présentes dans `dofus_accounts.conf`
- attribue l’initiative `100` aux nouvelles entrées
- resynchronise le mute/unmute si les fenêtres sont ouvertes

Mettre à jour directement l’initiative d’un pseudo :

```bash
bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh --set-ini "Nayl" 120
```

Cette commande resynchronise aussi l’audio si les fenêtres sont ouvertes.

Editer les initiatives des comptes actifs depuis le terminal :

```bash
bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh --edit-active
```

Cette commande resynchronise aussi l’audio si les fenêtres sont ouvertes.

## Raccourci KDE

Dans KDE :
1. Ouvrir `Configuration du système`
2. Aller dans `Raccourcis`
3. Ajouter un raccourci personnalisé de type `Commande/URL`
4. Utiliser la commande :

```bash
bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh
```

Si nécessaire, tester avec :

```bash
DISPLAY=:0 bash /home/nayl/Projects/DofusRetroWindowSwitcher/switcher.sh
```

## Remarques

Le script fonctionne dans un environnement où `wmctrl` peut lister et activer les fenêtres. Sous Wayland, ce comportement peut être limité selon la session utilisée.
