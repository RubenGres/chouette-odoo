#!/bin/bash

set -e
cd `dirname $0`

function container_full_name() {
    # Retourne le nom complet du coneneur $1 si il est en cours d'exécution
    # workaround for /usr/local/bin/docker-compose ps: https://github.com/docker/compose/issues/1513
    ids=$(/usr/local/bin/docker-compose ps -q)
    if [ "$ids" != "" ] ; then
        echo `docker inspect -f '{{if .State.Running}}{{.Name}}{{end}}' $ids \
              | cut -d/ -f2 | grep -E "_${1}_[0-9]"`
    fi
}

function dc_dockerfiles_images() {
    # Retourne la liste d'images Docker depuis les Dockerfile build listés dans docker-compose.yml
    local DOCKERDIRS=`grep -E '^\s*build:' docker-compose.yml|cut -d: -f2 |xargs`
    local dockerdir
    for dockerdir in $DOCKERDIRS; do
        echo `grep "^FROM " ${dockerdir}/Dockerfile |cut -d' ' -f2|xargs`
    done
}

function dc_exec_or_run() {
    # Lance la commande $2 dans le container $1, avec 'exec' ou 'run' selon si le conteneur est déjà lancé ou non
    local options=
    while [[ "$1" == -* ]] ; do
        options="$options $1"
        shift
    done
    local CONTAINER_SHORT_NAME=$1
    local CONTAINER_FULL_NAME=`container_full_name ${CONTAINER_SHORT_NAME}`
    shift
    if test -n "$CONTAINER_FULL_NAME" ; then
        # container already started
        docker exec -it $options $CONTAINER_FULL_NAME "$@"
    else
        # container not started
        /usr/local/bin/docker-compose run --rm $options $CONTAINER_SHORT_NAME "$@"
    fi
}

function select_database() {
    # Enregistre le nom de la base de données à utiliser dans la variable 'database'
    readarray -t database < <( $0 listdb )
    if [ ${#database[@]} -gt 1 ] ; then
        echo "Quellle base de données utiliser?" > /dev/stderr
        local i
        for i in "${!database[@]}"; do
            echo " $i : ${database[$i]}" > /dev/stderr
        done
        local index
        read -n 1 -r -p '?' index > /dev/stderr
        echo > /dev/stderr
        if [ "$index" -ge 0 -a "$index" -lt ${#database[@]} ]; then
            database="${database[$index]}"
        else
            exit -1;
        fi
    fi
}

case $1 in
    #-------------------------------------------------------------------------
    "")
        test -e data/odoo/etc/openerp-server.conf || $0 init
        test -e AwesomeFoodCoops/odoo || $0 init
        /usr/local/bin/docker-compose up -d
        ;;

    #-------------------------------------------------------------------------
    init)
        test -e docker-compose.yml || cp docker-compose.yml.dev docker-compose.yml
        test -e data/odoo/etc/openerp-server.conf \
            || cp data/odoo/etc/openerp-server.conf.dist data/odoo/etc/openerp-server.conf
        /usr/local/bin/docker-compose run --rm db chown -R postgres:postgres /var/lib/postgresql
        /usr/local/bin/docker-compose run --rm -u root odoo bash -c \
            "chown -R odoo:odoo /etc/odoo/*.conf; chmod -R 777 /var/lib/odoo"
        ;;

    #-------------------------------------------------------------------------
    upgrade)
        echo "Mise à jour:"
        echo " - des images des conteneurs Docker"
        echo " - des sources Odoo depuis le repository git AwesomeFoodCoops"
        read -rp "Êtes-vous sûr ? (o/n) "
        if [[ $REPLY =~ ^[oO]$ ]] ; then

            # Pour Odoo nous utilisons:
            # - soit une version venant d'une image Docker
            # - soit directement les sources AwesomeFoodCoops/odoo
            #   dont le volume est monté dans le conteneur.
            #
            # Pour la version d'Odoo contenue dans une image Docker,
            # on détecte les changements de version en vérifiant la
            # valeur de la variable d'environment ODOO_RELEASE.
            #
            # Pour la version d'Odoo AwesomeFoodCoops/odoo dont les sources
            # sont gérées sous Git, on détecte les changements de version en
            # vérifiant le dernier commit sur la branche 9.0 (la branche principale)

            echo "Fetch git submodule AwesomeFoodCoops 9.0 branch"
            # get hash of previous last commit on 9.0 branch:
            old_AwesomeFoodCoops_commit=`cd AwesomeFoodCoops && git log 9.0 -n 1 --pretty=format:"%H"`
            echo "old AwesomeFoodCoops commit $old_AwesomeFoodCoops_commit"
            # fetch localy remote update on 9.0 branch:
            (cd AwesomeFoodCoops && git fetch origin)
            # get hash of last commit on 9.0 branch:
            new_AwesomeFoodCoops_commit=`cd AwesomeFoodCoops && git log 9.0 -n 1 --pretty=format:"%H"`
            echo "new AwesomeFoodCoops commit $new_AwesomeFoodCoops_commit"

            echo "Get latest AwesomeFoodCoops Odoo requirements.txt and debian build scripts"
            for buildfile in debian/postinst debian/control requirements.txt ; do
                (cd AwesomeFoodCoops/odoo && git checkout 9.0 -- "$buildfile")
                if diff "AwesomeFoodCoops/odoo/$buildfile" odoo/$buildfile > /dev/null ; then
                    # copy it to odoo Docker image build directory:
                    cat "AwesomeFoodCoops/odoo/$buildfile" > "odoo/$buildfile"
                fi
                # Reset it to the version we where using in our local branch
                # to not break following  gitrebase cmd"
                (cd AwesomeFoodCoops/odoo && git reset HEAD "$buildfile")
                (cd AwesomeFoodCoops/odoo && git checkout --  "$buildfile")
            done

            echo "Pull latest Docker images from Docker Hub"
            old_release=`dc_exec_or_run odoo env|grep ODOO_RELEASE || true`
            echo "old_release $old_release"
            /usr/local/bin/docker-compose pull
            for image in `dc_dockerfiles_images`; do
                docker pull $image
            done
            echo "Build local Docker images"
            /usr/local/bin/docker-compose build
            echo "Stop and delete Dokcer containers"
            /usr/local/bin/docker-compose stop
            /usr/local/bin/docker-compose rm -f

            new_release=`dc_exec_or_run odoo env|grep ODOO_RELEASE || true`
            echo "new_release $new_release"

            if [ "$new_release" != "$old_release" -o "$new_AwesomeFoodCoops_commit" != "$old_AwesomeFoodCoops_commit" ] ; then
                echo "**************************************************"
                if [ "$new_release" != "$old_release" ] ; then
                    echo "* NOUVELLE VERSION ODOO : $new_release"
                    modules="all"
                fi
                if [ "$new_AwesomeFoodCoops_commit" != "$old_AwesomeFoodCoops_commit" ] ; then
                    echo "* NOUVEAU COMMIT AwesomeFoodCoops : $new_AwesomeFoodCoops_commit"
                    modules=`$0 modified_addons "$old_AwesomeFoodCoops_commit" "$new_AwesomeFoodCoops_commit"`
                    for addon in `$0 missing_addons`; do
                        echo ""
                        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        echo "!! ERREUR: le module installé $addon"
                        echo "!!         n'est plus disponible dans les sources !"
                        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
                        echo ""
                    done
                fi
                echo "* IL FAUT METTRE À JOUR LA BASE DE DONNEE D'ODOO"
                echo "**************************************************"
                $0 update "all" $modules
            else
                # Relaunch normally:
                $0
            fi
        fi
        ;;

    #-------------------------------------------------------------------------
    modified_addons)
        # Retourne la liste des addons modifiés dans le repository
        # AwesomeFoodCoops entre la révision passée en paramètre $1
        shift
        if [ -z "$1" ] ; then
            echo "ERREUR: version AwesomeFoodCoops non spécifiée" > /dev/stderr
            exit -1
        else
            # Filtre les répertoires contenus souns un répertoire
            # dont le nom se termine par "addons":
            ((cd AwesomeFoodCoops && git diff --name-only "$@") \
                | awk '{ if (match($0,/.*addons\/([^/]*)\//,m)) print m[1] }' \
                | sort | uniq)
        fi
        ;;

    missing_addons)
        # Liste les addons installés dont le repertoire source est introuvable
        installed_addons=`mktemp /tmp/installed_addons.XXXXXXXXXX`
        available_addons=`mktemp /tmp/available_addons.XXXXXXXXXX`
        ls -d addons/*/* \
              data/odoo/files/addons/9.0/* \
              AwesomeFoodCoops/odoo/openerp/addons/* \
              AwesomeFoodCoops/odoo/addons/* \
              AwesomeFoodCoops/*_addons/* \
            | xargs -n 1 basename | sort | uniq \
            > $available_addons
        (for database in `$0 listdb`; do $0 listmod $database ; done) | sort | uniq > $installed_addons
        comm -2 -3 $installed_addons $available_addons
        rm -f $installed_addons
        rm -f $available_addons
        ;;


    #-------------------------------------------------------------------------
    update)
        # Mise à jour de la base Odoo en le lancant avec la commande -u $2
        # sur la base $1
        for addon in `$0 missing_addons`; do
            echo ""
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "!! ERREUR: le module installé $addon"
            echo "!!         n'est plus disponible dans les sources !"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo ""
        done
        shift
        databases="$1"
        shift
        # La liste des modules doit être une liste spéarée par des virgules:
        modules=`echo -n $* |tr '\n' ","|tr " " ","`
        if [ -z "$modules" ] ; then
            modules="all"
        fi
        if [ -z "$database" -o "$database" = "all" ] ; then
            databases=`$0 listdb`
        fi
        echo "Mise à jour des bases Odoo, voire https://doc.odoo.com/install/linux/updating/"
        echo "  databases = $databases"
        echo "  modules = $modules"
        read -rp "Êtes-vous sûr ? (o/n) "
        if [[ $REPLY =~ ^[oO]$ ]] ; then
            function backup_and_update () {
                local database=$1
                local modules=$2
                local backupfile="pg_dump-$database-`date '+%Y-%m-%dT%H:%M:%S'`.gz"
                echo "Sauvegarde avant mise à jour de la base $database dans $backupfile"
                $0 pg_dump --clean $database |gzip > "$backupfile"
                /usr/local/bin/docker-compose run --rm odoo openerp-server -u "$modules" --stop-after-init -d "$database"
                $0 cleanup "$database"
            }
            $0 init
            /usr/local/bin/docker-compose stop odoo
            for database in $databases ; do
                backup_and_update "$database" "$modules"
            done
            $0
        fi
        ;;

    #-------------------------------------------------------------------------
    cleanup)
        # nétoie la base  Odoo $1 des données créées automatiquement depuis
        # le code source d'Odoo quand la base est mise à jour avec la commande
        #       openerp-server -u all
        shift
        $0 psql "$@" << EO_DB_CLEANUP
            DO
            \$\$
            BEGIN
                IF EXISTS (SELECT * FROM pg_tables WHERE tablename='website_menu' AND schemaname='public')
                THEN
                    -- remove website_menu "Shop","Blog" and "Contact us"
                    DELETE FROM website_menu
                    WHERE url in ('/shop', '/blog/1', '/page/contactus')
                      -- check also that these items have just been created by the system:
                      AND create_date > (current_timestamp - '0.5 day'::interval)
                      AND create_uid=1
                      AND write_date=create_date
                      AND write_uid=create_uid;
                END IF;
            END
            \$\$;
EO_DB_CLEANUP
        ;;

    #-------------------------------------------------------------------------
    prune)
        read -rp "Êtes-vous sûr de vouloir effacer les conteneurs et images Docker innutilisés ? (o/n)"
        if [[ $REPLY =~ ^[oO]$ ]] ; then
            # Note: la commande docker system prune n'est pas dispo sur les VPS OVH
            # http://stackoverflow.com/questions/32723111/how-to-remove-old-and-unused-docker-images/32723285
            exited_containers=$(docker ps -qa --no-trunc --filter "status=exited")
            test "$exited_containers" != ""  && docker rm $exited_containers
            dangling_images=$(docker images --filter "dangling=true" -q --no-trunc)
            test "$dangling_images" != "" && docker rmi $dangling_images
        fi
        ;;

    #-------------------------------------------------------------------------
    debug)
        /usr/local/bin/docker-compose stop odoo
        shift
        /usr/local/bin/docker-compose run --rm odoo openerp-server \
            --logfile=/dev/stdout --log-level=debug \
            --debug --dev \
            "$@"
        ;;

    #-------------------------------------------------------------------------
    bash)
        dc_exec_or_run odoo "$@"
        ;;

    #-------------------------------------------------------------------------
    bashroot)
        shift
        dc_exec_or_run --user=root odoo bash "$@"
        ;;

    #-------------------------------------------------------------------------
    shell)
        shift
        if [ $# == 0 ] ; then select_database; set -- $database ; fi
        dc_exec_or_run odoo odoo.py shell -d "$@"
        ;;

    #-------------------------------------------------------------------------
    psql|pg_dump|pg_dumpall|dumpall)
        cmd=$1
        shift
        if [ "$cmd" = "psql" ] ; then
            # check if input file descriptor (0) is a terminal
            if [ -t 0 ] ; then
                option="-it";
            else
                option="-i";
            fi
        else
            option="";
            if [ "$cmd" = "dumpall" ] ; then
                cmd=pg_dumpall
                set -- -c "$@" # Include SQL commands to clean (drop) databases before recreating them.
            fi
        fi
        POSTGRES_USER=`grep POSTGRES_USER docker-compose.yml|cut -d= -f2`
        POSTGRES_PASS=`grep POSTGRES_PASS docker-compose.yml|cut -d= -f2|xargs`
        DB_CONTAINER=`container_full_name db`
        if [ "$DB_CONTAINER" = "" ] ; then
            echo "Démare le conteneur db" > /dev/stderr
            /usr/local/bin/docker-compose up -d db > /dev/stderr
            sleep 3
            DB_CONTAINER=`container_full_name db`
        fi
        if [ $# == 0 ] && [ $cmd != "pg_dumpall" ]; then select_database; set -- $database ; fi
        docker exec $option $DB_CONTAINER env PGPASSWORD="$POSTGRES_PASS" PGUSER=$POSTGRES_USER $cmd "$@"
        ;;

    #-------------------------------------------------------------------------
    dumpfordiff)
        select_database
        $0 bash -c "/mnt/extra-addons/chouette/tools/pseudo_pg_dump_for_diff.py $database"
        ;;

    #-------------------------------------------------------------------------
    restoreall)
        shift
        POSTGRES_USER=`grep POSTGRES_USER docker-compose.yml|cut -d= -f2`
        POSTGRES_PASS=`grep POSTGRES_PASS docker-compose.yml|cut -d= -f2|xargs`
        DB_CONTAINER=`container_full_name db`
        docker exec -i $DB_CONTAINER env PGPASSWORD="$POSTGRES_PASS" PGUSER=$POSTGRES_USER psql "$@"
        ;;

    #-------------------------------------------------------------------------
    listdb)
        echo "SELECT datname FROM pg_database WHERE datistemplate=false AND NOT datname in ('postgres','odoo');" | $0 psql -A -t postgres
        ;;

    #-------------------------------------------------------------------------
    listmod)
        shift
        if [ $# == 0 ] ; then select_database; set -- $database ; fi
        echo "SELECT name FROM ir_module_module WHERE state='installed' ORDER BY name;" | $0 psql -A -t "$@"
        ;;

    #-------------------------------------------------------------------------
    listtopmod)
        # Liste les modules Odoo installés dont aucun autre module ne dépend
        # et qui ne sont pas "auto_install" (cad non installés automatiquement
        # si toutes leur dépendances sont installées).
        # En théorie, partir d'une base vierge et installer uniquement
        # la liste de modules retournée par cette commande devrait suffir
        # pour installer la même liste complète de modules (liste retournée
        # par la commande listmod).
        shift
        if [ $# == 0 ] ; then select_database; set -- $database ; fi
        $0 psql -A -t "$@" << EOSQLTOPMOD
            SELECT name FROM ir_module_module
            WHERE state='installed'
              AND auto_install=false
              AND name NOT IN
                (SELECT dep.name
                 FROM ir_module_module_dependency AS dep
                 INNER JOIN ir_module_module AS mod
                 ON dep.module_id=mod.id
                 WHERE mod.state='installed'
                   AND mod.auto_install=false)
            ORDER BY name;
EOSQLTOPMOD
        ;;

    list_github_addons)
        # Liste les url github de chaque addons
        function filter_directory_add_prefix() {
            prefix="$1"
            while read -r path; do
                if test -d "$path"; then
                    echo "$prefix$path"
                fi
            done
        }
        ls -d addons/*/* | filter_directory_add_prefix https://github.com/lachouettecoop/chouette-odoo/tree/master/
        (cd AwesomeFoodCoops && ls -d *_addons/* | filter_directory_add_prefix https://github.com/AwesomeFoodCoops/odoo-production/tree/9.0/)
        ;;


    #-------------------------------------------------------------------------
    build|config|create|down|events|exec|kill|logs|pause|port|ps|pull|restart|rm|run|start|stop|unpause|up)
        /usr/local/bin/docker-compose "$@"
        ;;

    #-------------------------------------------------------------------------
    *)
        cat <<HELP
Utilisation : $0 [COMMANDE]
  init         : initialise les données
               : lance les conteneurs
  upgrade      : met à jour les images et les conteneurs Docker
  update       : met à jour la base Odoo suite à un changement de version mineure
  prune        : efface les conteneurs et images Docker inutilisés
  debug        : lance Odoo en mode debug
  bash         : lance bash sur le conteneur odoo
  bashroot     : lance bash sur le conteneur odoo, en tant qu'utilisateur root
  shell        : lance Odoo shell (python)
  psql         : lance psql sur le conteneur db
  pg_dump      : lance pg_dump sur le conteneur db
  dumpall      : lance pg_dumpall sur le conteneur db
  restoreall   : permet de restaure le contenu d'un dumpall
  dumpfordiff  : pseudo dump de la base dans un format plus facile a comparer textuellement
  listdb       : liste les bases de données
  listmod      : liste les modules Odoo installés
  listtopmod   : liste les modules Odoo installés dont aucun autre module ne dépend
  stop         : stope les conteneurs
  rm           : efface les conteneurs
  logs         : affiche les logs des conteneurs
HELP
        ;;
esac

