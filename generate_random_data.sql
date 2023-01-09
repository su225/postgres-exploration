INSERT INTO test VALUES (
  (SELECT string_agg(chr(trunc(65+random()*26)::integer),'') FROM generate_series(1,8000)));