# glpi-autoinstall

Script d'installation automatique de **GLPI** sur **Debian 12 et 13**, avec Apache2, PHP-FPM et MariaDB.
Une seule commande sur une Debian fraîchement installée suffit : le script pose quelques questions (avec des valeurs proposées par défaut) et s'occupe de tout le reste.

## Installation rapide

Sur la machine Debian, en root (ou avec `sudo`) :

```bash
wget https://raw.githubusercontent.com/emorboeuf/glpi-autoinstall/main/install-glpi.sh
sudo bash install-glpi.sh
```

Ou en une seule ligne :

```bash
wget -qO- https://raw.githubusercontent.com/emorboeuf/glpi-autoinstall/main/install-glpi.sh | sudo bash
```

> `wget` est présent par défaut sur Debian, `curl` ne l'est pas toujours.

## Ce que le script demande

| Question | Valeur proposée |
|---|---|
| Version de GLPI | dernière version compatible avec la Debian détectée |
| Nom ou IP du serveur | adresse IP de la machine |
| Nom de la base / utilisateur SQL | `glpi` / `glpi` |
| Mot de passe SQL | généré automatiquement si on appuie sur Entrée |
| Langue | `fr_FR` |
| Fuseau horaire | fuseau du système, sinon `Europe/Paris` |
| HTTPS (certificat auto-signé) | non |
| Arborescence sécurisée | oui |

Un récapitulatif s'affiche avant de lancer quoi que ce soit.

## Version de GLPI selon Debian

| Debian | PHP fourni | GLPI installé |
|---|---|---|
| 12 (Bookworm) | 8.2 | GLPI 11.x |
| 13 (Trixie) | 8.4 | GLPI 12.x par défaut (11.x possible) |

GLPI 12 demande PHP 8.3 minimum, c'est pour ça que Debian 12 reste sur GLPI 11.
La liste des versions est récupérée en direct sur GitHub : le script installe toujours la dernière version publiée.

## Ce que fait le script

1. Vérifie qu'il tourne en root sur Debian 12 ou 13 et que GitHub est joignable
2. Installe Apache2, MariaDB, PHP-FPM et les extensions PHP nécessaires à GLPI
3. Crée la base et l'utilisateur SQL, importe les fuseaux horaires dans MariaDB
4. Télécharge l'archive officielle de GLPI depuis `github.com/glpi-project/glpi`
5. Si l'option est choisie, range la config dans `/etc/glpi`, les données dans `/var/lib/glpi` et les journaux dans `/var/log/glpi` (hors du dossier web)
6. Configure PHP (fuseau, limites, cookies de session sécurisés)
7. Crée le site Apache, avec `DocumentRoot` sur `/var/www/glpi/public` comme l'exige GLPI 11+
8. Installe GLPI en ligne de commande (`bin/console db:install`), supprime `install/install.php` et ajoute la tâche cron

## Mode automatique (sans questions)

Pratique pour déployer plusieurs machines ou tester en boucle :

```bash
sudo DB_PASS='MonMotDePasse123' SERVER_NAME=glpi.local ENABLE_HTTPS=o bash install-glpi.sh --yes
```

Variables disponibles : `GLPI_VERSION`, `DB_NAME`, `DB_USER`, `DB_PASS`, `SERVER_NAME`, `GLPI_LANG`, `PHP_TZ`, `ENABLE_HTTPS`, `SECURE_LAYOUT`, `FORCE_REINSTALL` (détail avec `bash install-glpi.sh --help`).

## Après l'installation

- Ouvrir l'URL affichée à la fin et se connecter avec `glpi` / `glpi`
- **Changer tout de suite** les mots de passe des comptes par défaut : `glpi`, `tech`, `normal`, `post-only`
- Le récapitulatif (avec le mot de passe SQL) est enregistré dans `/root/glpi-install-info.txt`
- Le journal complet de l'installation se trouve dans `/var/log/glpi-install.log`

## Si une installation existe déjà

Le script le détecte (dossier `/var/www/glpi` ou base existante) et demande une confirmation explicite avant de **tout supprimer** (fichiers et base). En mode `--yes`, il s'arrête sans rien toucher, sauf si `FORCE_REINSTALL=o` est passé.

## Dépannage

| Problème | Piste |
|---|---|
| `apt-get update a échoué` | vérifier le réseau, le DNS et le proxy de la machine |
| `Impossible de joindre l'API GitHub` | GitHub bloqué par le pare-feu, ou plus de 60 requêtes par heure depuis la même IP |
| Page blanche ou erreur 500 | `tail /var/log/apache2/glpi_error.log` et `/var/log/glpi/php-errors.log` |
| `$'\r': command not found` | le fichier a été enregistré avec des fins de ligne Windows (voir `.gitattributes`) |

## Licence

Script libre d'utilisation. GLPI est distribué sous licence GPLv3 par Teclib'.
