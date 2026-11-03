#!/bin/bash
# Fresh test DB for the v21+ suites: no old daily checklists, plus Kate and Liam.
bash "$(dirname "$0")/reset_db.sh" >/dev/null 2>&1
psql -h /var/tmp -p 54329 -U postgres -q -d bk -Atc "delete from tasks; insert into staff (id, name, roles) values ('kate','Kate','{closing-bartender}'),('liam','Liam','{dishwasher}') on conflict do nothing; select admin_set_pin('Kate','2222'); select admin_set_pin('Liam','5555');" >/dev/null
