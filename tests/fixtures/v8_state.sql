insert into invcats (id, name, sort) values ('liquor','Liquor',0) on conflict do nothing;
insert into items (id, cat_id, name, unit, par, supplier_id, added_at) select 'l'||n, 'liquor', nm, 'Bottles', par, '2kj59bzmiz7d0mtorm4h', now() + n*interval '1 ms'
from (values (1,'Grey Goose Vodka',2),(2,'Ketel One Vodka',2),(3,'Pinnacle Whipped',4),(4,'Tito''s Vodka',12),(5,'Stoli Vodka',6),(6,'Stoli Orange Vodka',2),
             (7,'Stoli Blueberry Vodka',1),(8,'Stoli Raspberry Vodka',2),(9,'Stoli Cucumber Vodka',1),(10,'Jameson Irish Whiskey',6),(11,'Captain Morgan Spiced Rum',4),(12,'Patron Silver Tequila',2)) v(n,nm,par);
insert into counts (item_id, on_hand, counted_by_name, counted_at) select 'l'||n, oh, 'Aidan', now() from (values (1,2),(2,2),(3,4),(4,12),(5,6),(6,1),(7,1),(8,2),(10,3)) v(n,oh);
insert into items (id, cat_id, name, unit, par) values ('limes','bar-supplies','Limes','cases',6),('napkins','paper-products','Beverage napkins','cases',2);
insert into counts values ('limes',2,null,'Jill',now());
