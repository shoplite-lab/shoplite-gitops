-- Database-per-service: each service owns one database + one login role.
-- LOCAL ONLY. On Kubernetes, CloudNativePG creates these from Secrets.
CREATE ROLE users_app LOGIN PASSWORD 'users_pw';
CREATE DATABASE users OWNER users_app;

CREATE ROLE products_app LOGIN PASSWORD 'products_pw';
CREATE DATABASE products OWNER products_app;

CREATE ROLE orders_app LOGIN PASSWORD 'orders_pw';
CREATE DATABASE orders OWNER orders_app;

CREATE ROLE notifications_app LOGIN PASSWORD 'notifications_pw';
CREATE DATABASE notifications OWNER notifications_app;

CREATE ROLE keycloak_app LOGIN PASSWORD 'keycloak_pw';
CREATE DATABASE keycloak OWNER keycloak_app;
