# ShutterTAS

Outil de **Tool-Assisted Speedrun (TAS)** pour *Shutter*, basé sur **UE4SS**.

Le projet permet d'ajouter progressivement des fonctionnalités de TAS au jeu, notamment la sauvegarde et le chargement d'états du jeu. La première étape du projet consiste à identifier les objets et états internes de *Shutter* afin de construire un système de sauvegarde/restauration fiable.

> **Statut : expérimental**
>
> Le projet est actuellement en phase de développement. Les fonctionnalités disponibles peuvent changer et certaines fonctions peuvent ne pas encore être implémentées.

---

## Sommaire

- [Prérequis](#prérequis)
- [1. Installer UE4SS](#1-installer-ue4ss)
- [2. Vérifier l'installation de UE4SS](#2-vérifier-linstallation-de-ue4ss)
- [3. Installer ShutterTAS](#3-installer-shuttertas)
- [4. Structure des fichiers](#4-structure-des-fichiers)
- [5. Lancer ShutterTAS](#5-lancer-shuttertas)
- [6. Vérifier que le mod fonctionne](#6-vérifier-que-le-mod-fonctionne)
- [7. Fichiers générés](#7-fichiers-générés)
- [8. Dépannage](#8-dépannage)
- [9. Développement](#9-développement)

---

# Prérequis

Vous devez avoir :

- *Shutter* installé via Steam
- une version de **UE4SS compatible avec le jeu**
- Windows
- accès au dossier d'installation de *Shutter*

Le chemin d'installation de Steam ressemble généralement à :

```text
C:\Program Files (x86)\Steam\steamapps\common\Shutter\
```

Cependant, votre jeu peut être installé dans un autre dossier ou sur un autre disque.

---

# 1. Installer UE4SS

## 1.1 Télécharger UE4SS

Téléchargez une version récente de **UE4SS (UE4SS / UE4SS-RE)** compatible avec *Shutter*.

Après téléchargement, vous devriez obtenir une archive contenant notamment des fichiers tels que :

```text
UE4SS.dll
UE4SS-settings.ini
dwmapi.dll
Mods\
```

> ⚠️ La structure exacte peut varier selon la version de UE4SS utilisée.

---

## 1.2 Trouver le dossier du jeu

Dans Steam :

1. Ouvrez votre bibliothèque Steam.
2. Faites un clic droit sur **Shutter**.
3. Sélectionnez **Propriétés**.
4. Allez dans **Fichiers installés**.
5. Cliquez sur **Parcourir**.

Vous arrivez dans le dossier contenant l'exécutable du jeu.

Vous devez identifier le dossier contenant le fichier `.exe` principal de *Shutter*.

---

## 1.3 Identifier le dossier `Binaries`

Pour un jeu Unreal Engine 4, l'organisation ressemble généralement à :

```text
Shutter\
└── Shutter\
    └── Binaries\
        └── Win64\
            └── Shutter-Win64-Shipping.exe
```

Le dossier important pour UE4SS est généralement :

```text
Shutter\Shutter\Binaries\Win64\
```

Placez les fichiers nécessaires à UE4SS dans ce dossier selon la structure fournie par votre version de UE4SS.

Après installation, vous devriez notamment avoir quelque chose ressemblant à :

```text
Win64\
├── Shutter-Win64-Shipping.exe
├── UE4SS.dll
├── UE4SS-settings.ini
├── dwmapi.dll
└── Mods\
```

> **Important :** ne renommez pas l'exécutable du jeu.

---

# 2. Vérifier l'installation de UE4SS

Lancez **Shutter depuis Steam**.

Si UE4SS est correctement chargé, il devrait créer/utiliser un dossier de mods dans le répertoire du jeu.

Vous devriez pouvoir trouver une structure similaire à :

```text
Win64\
└── Mods\
```

Selon la version de UE4SS, des fichiers supplémentaires peuvent également être créés.

### Vérification avec la console UE4SS

Certaines installations de UE4SS permettent d'afficher une console lorsqu'un jeu est lancé.

Si elle est disponible, vous devriez voir des messages indiquant que UE4SS a été chargé.

Si vous ne voyez absolument aucun signe de UE4SS, consultez la section [Dépannage](#8-dépannage).

---

# 3. Installer ShutterTAS

## 3.1 Créer le dossier du mod

Dans le dossier `Mods` de UE4SS, créez :

```text
ShutterTASDiscovery
```

La structure doit devenir :

```text
Mods\
└── ShutterTASDiscovery\
```

---

## 3.2 Installer le script Lua

Le script principal doit être placé dans :

```text
Mods\ShutterTASDiscovery\Scripts\main.lua
```

La structure complète devient :

```text
Mods\
└── ShutterTASDiscovery\
    └── Scripts\
        └── main.lua
```

---

## 3.3 Activer le mod

Selon la version de UE4SS utilisée, les mods sont généralement activés depuis :

```text
Mods\mods.txt
```

Ajoutez :

```text
ShutterTASDiscovery : 1
```

Exemple :

```text
ShutterTASDiscovery : 1
```

> La syntaxe exacte de `mods.txt` peut dépendre de la version de UE4SS. Utilisez la syntaxe présente dans le fichier `mods.txt` fourni avec votre installation.

---

# 4. Structure des fichiers

Une installation fonctionnelle devrait ressembler approximativement à :

```text
Shutter\
└── Shutter\
    └── Binaries\
        └── Win64\
            ├── Shutter-Win64-Shipping.exe
            │
            ├── UE4SS.dll
            ├── UE4SS-settings.ini
            ├── ...
            │
            └── Mods\
                │
                ├── mods.txt
                │
                └── ShutterTASDiscovery\
                    │
                    └── Scripts\
                        └── main.lua
```

Les noms et fichiers supplémentaires peuvent varier selon la version de UE4SS.

---

# 5. Lancer ShutterTAS

Une fois UE4SS et le mod installés :

1. Fermez complètement *Shutter* s'il est déjà lancé.
2. Lancez *Shutter* depuis Steam.
3. Attendez que le jeu arrive au menu ou charge une partie.
4. UE4SS charge automatiquement `ShutterTASDiscovery`.
5. Le script attend quelques secondes avant d'effectuer sa découverte.

Vous n'avez normalement **pas besoin de lancer `main.lua` manuellement**.

Le chargement est effectué par UE4SS.

---

# 6. Vérifier que le mod fonctionne

Le premier script de découverte utilise :

```lua
ForEachUObject(...)
```

pour parcourir les objets Unreal présents en mémoire.

Lorsque le script fonctionne, la console UE4SS devrait afficher quelque chose ressemblant à :

```text
[ShutterTAS] Candidate:
...
```

ou :

```text
[ShutterTAS] Runtime actor discovery complete: XX objects
```

Selon le script installé, un fichier de résultat peut également être créé dans :

```text
Mods\ShutterTASDiscovery\
```

Par exemple :

```text
discovery.txt
```

ou :

```text
player_candidates.txt
```

---

# 7. Fichiers générés

Les scripts ShutterTAS utilisent actuellement des fichiers texte pour faciliter l'analyse du jeu.

Par exemple :

```text
Mods\ShutterTASDiscovery\discovery.txt
```

Ces fichiers permettent de conserver une liste des objets Unreal trouvés pendant l'exécution.

On peut notamment y trouver des objets appartenant aux niveaux de *Shutter* :

```text
/Game/Maps/Shutter/010_Intro_Map...
/Game/Maps/Shutter/030_Lobby_Map...
```

avec des objets tels que :

```text
LS_Trigger_C
Door_C
CircularDoor_C
DialogueTrigger_C
BP_SpawnPoint_...
```

Cette phase sert à déterminer quels objets représentent réellement l'état du jeu.

---

# 8. Dépannage

## UE4SS ne semble pas se charger

Vérifiez que les fichiers UE4SS sont placés dans le bon dossier :

```text
...\Shutter\...\Binaries\Win64\
```

et non dans :

```text
...\Shutter\
```

ou :

```text
...\Shutter\Content\
```

---

## Le mod n'est pas chargé

Vérifiez :

```text
Mods\mods.txt
```

et assurez-vous que le mod est activé.

La ligne devrait ressembler à :

```text
ShutterTASDiscovery : 1
```

Vérifiez également que le fichier existe bien :

```text
Mods\ShutterTASDiscovery\Scripts\main.lua
```

---

## Le script Lua produit une erreur

Consultez la console UE4SS ou les logs.

Par exemple :

```text
Lua::call_function
LUA_ERRRUN
```

indique qu'une erreur d'exécution Lua s'est produite.

Copiez **l'intégralité du message d'erreur**, notamment la ligne :

```text
main.lua:XX
```

Cela permet de déterminer exactement quelle fonction ou quelle ligne pose problème.

---

## Le script ne trouve pas le joueur

C'est un cas important pour Shutter.

Un objet contenant le mot `Player` dans son nom n'est pas nécessairement le joueur.

Par exemple :

```text
AnimationPlayer
```

peut appartenir à un système d'animation ou de séquence.

C'est pourquoi ShutterTAS utilise progressivement une découverte plus précise des classes et objets runtime.

**Ne modifiez pas simplement le filtre pour rechercher tous les objets contenant `player`.**

---

# 9. Développement

Le développement de ShutterTAS se fait progressivement.

L'objectif est de passer de :

```text
UE4SS
   │
   ▼
Découverte des objets Unreal
   │
   ▼
Identification du joueur
   │
   ▼
Lecture de son état
   │
   ▼
Sauvegarde de l'état
   │
   ▼
Restauration de l'état
   │
   ▼
Sauvegarde de l'état du jeu
   │
   ▼
TAS complet
```

## Première étape : position du joueur

Le premier test consiste à pouvoir :

```text
SAVE
 ↓
Position + rotation du joueur
 ↓
Déplacement du joueur
 ↓
LOAD
 ↓
Position + rotation restaurées
```

Une fois cette étape fonctionnelle, le système pourra progressivement intégrer :

- position et rotation
- vitesse et mouvement
- état du personnage
- inventaire
- objets ramassés
- portes
- interrupteurs
- puzzles
- triggers
- progression
- dialogues
- timers
- objets spawnés dynamiquement
- états du `GameState`
- états du `PlayerState`
- états du `GameInstance`

L'objectif final n'est pas simplement de créer une sauvegarde classique, mais de pouvoir **restaurer un état suffisamment complet pour permettre un TAS reproductible et déterministe**.

---

## ⚠️ État actuel du projet

ShutterTAS est actuellement un **outil de développement expérimental**.

Les scripts de découverte ne modifient pas volontairement la progression du jeu. Ils servent principalement à comprendre la structure runtime de *Shutter* avant d'implémenter le système de sauvegarde/restauration.

Il est recommandé d'utiliser une sauvegarde de jeu séparée pour les tests.

---

## Licence

À compléter selon la licence choisie pour le projet.

## Crédits

- *Shutter* — Teamscooo
- **UE4SS** — UE4SS development team
- **ShutterTAS** — projet communautaire TAS