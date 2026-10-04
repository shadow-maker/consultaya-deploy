-- ConsultaYa · creación de roles y bases en RDS PostgreSQL (una vez; se puede repetir).
--
-- Uso (desde la EC2, ver docs/06-despliegue-aws.md · Paso 4):
--   cp scripts/init-rds.sql /tmp/init.sql
--   # Editar /tmp/init.sql y reemplazar las 3 contraseñas <PASSWORD_...>
--   psql "host=<endpoint-rds> user=postgres_admin dbname=postgres sslmode=require" -f /tmp/init.sql
--   rm /tmp/init.sql
--
-- NO commitear este archivo con contraseñas reales.
-- Idempotente: si el rol existe se actualiza su contraseña; si la base existe no se toca.
-- Falla si quedó algún marcador <PASSWORD_...> sin reemplazar.

\set ON_ERROR_STOP on

-- Un rol LOGIN por servicio ----------------------------------------------------
DO $$
DECLARE
  pw text;
  rol text;
BEGIN
  FOR rol, pw IN VALUES
    ('consultaya_usuarios',  '<PASSWORD_USUARIOS>'),
    ('consultaya_lecciones', '<PASSWORD_LECCIONES>'),
    ('consultaya_progreso',  '<PASSWORD_PROGRESO>')
  LOOP
    IF left(pw, 1) = '<' THEN
      RAISE EXCEPTION 'Falta reemplazar la contraseña de % (marcador %)', rol, pw;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rol) THEN
      EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', rol, pw);
    ELSE
      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', rol, pw);
    END IF;
    -- RDS (PostgreSQL 16+): el administrador debe poder asumir el rol dueño para crear la base.
    EXECUTE format('GRANT %I TO CURRENT_USER', rol);
  END LOOP;
END
$$;

-- Una base por servicio, cuyo dueño es su rol ----------------------------------
SELECT 'CREATE DATABASE consultaya_usuarios OWNER consultaya_usuarios'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'consultaya_usuarios') \gexec

SELECT 'CREATE DATABASE consultaya_lecciones OWNER consultaya_lecciones'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'consultaya_lecciones') \gexec

SELECT 'CREATE DATABASE consultaya_progreso OWNER consultaya_progreso'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'consultaya_progreso') \gexec

-- Aislamiento: nadie más puede conectarse a las bases de otro servicio ---------
REVOKE ALL ON DATABASE consultaya_usuarios  FROM PUBLIC;
REVOKE ALL ON DATABASE consultaya_lecciones FROM PUBLIC;
REVOKE ALL ON DATABASE consultaya_progreso  FROM PUBLIC;

\echo 'Listo: roles y bases consultaya_{usuarios,lecciones,progreso} creados.'
