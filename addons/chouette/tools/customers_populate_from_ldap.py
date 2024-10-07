#!/usr/bin/env python
# -*- coding: utf-8 -*-

import sys
import ldap
import yaml
import os.path
import argparse
import xmlrpclib
from pprint( import pprint)

"""
Update the list of Odoo customers (contacts stored in res.partner table)
from the list of person in a LDAP directory using their associated
barcode as matching key.

The configuration file name should have the program file name with .yml
extension, and contain:
  ldap:
    url: ldap://ldap.mysite.com:389
    username: cn=login,dc=mysite,dc=com
    password: password
    dn: dc=mysite,dc=com
  odoo:
    db: dbname
    url: https://odoo.mysite.com
    username: login
    password: password
"""

# Looks for configuration file with same name and .yml extension in the same directory as this python script
YML_CONF_FILE = os.path.splitext(sys.argv[0])[0] + ".yml"

# Main class
# 1. Loads variables from configuration file
# 2. Connect and retrieve users from LDAP
# 3. Connect to Odoo
# 4. Update Odoo by mapping LDAP users to Odoo ones
def main(dry_run=False):
    conf = open_conf_file(YML_CONF_FILE)
    ldap_persons = search_ldap_persons(**conf["ldap"])
    odoo = OdooRPC(**conf["odoo"])
    update_odoo_customers(odoo, map(ldap_person_to_odoo_customer, ldap_persons), dry_run)


def ldap_person_to_odoo_customer(ldap_person):
    """Extract variable name, barcode, email"""
    #pprint((ldap_person))
    return {
        'name': decode_utf8(ldap_person['description'][0])
                + ' '
                + decode_utf8(ldap_person['sn'][0]),
        'barcode': ldap_person['homeDirectory'][0],
        'email': ldap_person['mail'][0],
        'active': True,
        'customer': True,
        'is_company': False,
    }


def update_odoo_customers(odoo, new_customers, dry_run=False):
    fields = new_customers[0].keys()

    old_customers = get_odoo_customers(odoo, fields)

    old_customers_dict = { customer["barcode"]:customer for customer in old_customers }
    new_customers_dict = { customer["barcode"]:customer for customer in new_customers }

    create_or_update_odoo_new_customers(odoo, old_customers_dict, new_customers_dict, dry_run)
    deactivate_odoo_old_customers(odoo, old_customers_dict, new_customers_dict, dry_run)


def get_odoo_customers(odoo, fields):
    # We need to search explicitely for additional active=False items because
    # they are filtered out by default.
    old_customers_ids = \
        odoo.search('res.partner',
            [[['is_company', '=', False], ['customer', '=', True]]]) \
        + odoo.search('res.partner',
            [[['is_company', '=', False], ['customer', '=', True], ['active', '=', False]]])
    return odoo.read('res.partner',
            [old_customers_ids], {'fields': fields})


def create_or_update_odoo_new_customers(odoo, old_customers_dict, new_customers_dict, dry_run=False):
    for barcode, new_cstmr in new_customers_dict.items():
        if not barcode:
            print( "# LDAP person without barcode:", new_cstmr["name"].encode("utf8"), new_cstmr["email"])
        if barcode not in old_customers_dict:
            print( "+ create customer", new_cstmr["name"].encode("utf8"), new_cstmr["email"])
            if not dry_run:
                id = odoo.create('res.partner', [new_cstmr])
                print( "    => id", id)
        else:
            old_cstmr = old_customers_dict[barcode]
            differences = {field:value for field,value in new_cstmr.items() if old_cstmr[field] != value}
            if differences:
                print( ('! update customer ' + str(old_cstmr['id']) + " " + old_cstmr['name'] + ' set ' + str(differences)).encode("utf8"))
                if not dry_run:
                    odoo.write('res.partner', [[old_cstmr["id"]], differences])

def deactivate_odoo_old_customers(odoo, old_customers_dict, new_customers_dict, dry_run=False):
    for barcode, old_cstmr in old_customers_dict.items():
        if not barcode:
            print( "# Odoo customer without barcode:", old_cstmr["id"], old_cstmr["name"].encode("utf8"), old_cstmr["email"])
        elif barcode not in new_customers_dict and old_cstmr['active']:
            print( '- deactivate customer', old_cstmr["id"], old_cstmr["name"].encode("utf8"), old_cstmr["email"])
            if not dry_run:
                odoo.write('res.partner', [[old_cstmr["id"]], {'active': False}])


def search_ldap_persons(url, dn, username, password):
    #Connect to ldap server
    ldp = ldap.initialize(url)
    ldp.protocol_version = ldap.VERSION3
    ldp.simple_bind_s(username, password)
    return [person for _,person in ldp.search_s(
        dn, ldap.SCOPE_SUBTREE, '(objectClass=person)')]


def decode_utf8(string):
    if type(string) == str:
        return string.decode("utf8")
    else:
        return string


class OdooRPC():
    """ This class provides an easy way to pilot Odoo servers through
        RPC (Remote Procedure Call) of its API
        https://www.odoo.com/documentation/9.0/api_integration.html
    """
    def __init__(self, url, db, username, password):
        self.url = url
        self.db = db
        self.username = username
        self.password = password
        self.common = xmlrpclib.ServerProxy(self.url + '/xmlrpc/2/common')
        self.uid = self.common.authenticate(db, username, password, {})
        self.object = xmlrpclib.ServerProxy(self.url + '/xmlrpc/2/object')

    def execute(self, *params):
        return self.object.execute_kw(self.db, self.uid, self.password, *params)

    def search(self, param1, *other_params):
        return self.execute(param1, 'search', *other_params)

    def read(self, param1, *other_params):
        return self.execute(param1, 'read', *other_params)

    def create(self, param1, *other_params):
        return self.execute(param1, 'create', *other_params)

    def write(self, param1, *other_params):
        return self.execute(param1, 'write', *other_params)

# Parses Configuration file and returns variables from that file
def open_conf_file(filename):
    """Open and return the content of the .yml configuration file.
       check that the required fields are present.
    """
    conf = yaml.load(open(filename))
    for section, fields in {"ldap":["url","username","password","dn"],
                            "odoo":["url","db","username","password"]}.items():
        if section not in conf:
            print( "ERREUR: missing section «{0}:» in {1}".format(section, filename))
            sys.exit(-1)
        else:
            fields = set(fields)
            actual_fields = set(conf[section].keys())
            for field in (fields - actual_fields):
                print( "ERROR: missing field «{0}:» in section «{1}:» of file {2}".format(field, section, filename))
                sys.exit(-1)
            for field in (actual_fields - fields):
                print( "ERROR: unknown field «{0}:» in section «{1}:» of file {2}".format(field, section, filename))
                sys.exit(-1)
    return conf

# -d option allows to show what would be changed
if __name__ == '__main__':
    parser = argparse.ArgumentParser(sys.argv[0], description="Synchonize Odoo customers from LDAP persons")
    parser.add_argument('-d', '--dry-run', dest='dry_run', action='store_true', help="only print( intended actions, don't actualy modify Odoo customers"))
    parser.set_defaults(dry_run=False)
    args = parser.parse_args()
    main(args.dry_run)
