-- Plan B local: bases del contenedor Postgres (docker-compose.localdb.yml).
-- Se ejecuta una sola vez, al crear el volumen. Solo bases consultaya_*.
CREATE DATABASE consultaya_usuarios;
CREATE DATABASE consultaya_usuarios_test;
CREATE DATABASE consultaya_lecciones;
CREATE DATABASE consultaya_lecciones_test;
CREATE DATABASE consultaya_progreso;
CREATE DATABASE consultaya_progreso_test;
