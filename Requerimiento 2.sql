-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  REQUERIMIENTO 2: FUNCIONES ALMACENADAS (con y sin parametros)
--
--  ORDEN DE EJECUCION: este archivo va ANTES que el Requerimiento 1,
--  porque los procedimientos del Req. 1 usan estas funciones.
--
--  Funciones:
--   2.1 fn_edad_paciente(p_pac_run)            -> con parametro
--   2.2 fn_porc_descto_3ra_edad(p_edad)        -> con parametro
--   2.3 fn_multa_diaria(p_esp_id)              -> con parametro
--   2.4 fn_copago_paciente(p_ate_id)           -> con parametro
--   2.5 fn_porc_incentivo(p_med_run, p_cant)   -> con parametros
--   2.6 fn_total_pagos_atrasados               -> SIN parametros
-- =====================================================================

SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- 2.1 EDAD DEL PACIENTE
-- Retorna la edad en anios cumplidos a la fecha actual.
-- Si el paciente no existe retorna -1 (controlado con NO_DATA_FOUND).
-- Se reutiliza en: fn_copago_paciente, sp_calcular_morosidad y packages.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_edad_paciente
  (p_pac_run IN NUMBER)
RETURN NUMBER
IS
  v_fec_nac  paciente.fecha_nacimiento%TYPE;
BEGIN
  SELECT fecha_nacimiento
    INTO v_fec_nac
    FROM paciente
   WHERE pac_run = p_pac_run;

  RETURN TRUNC(MONTHS_BETWEEN(SYSDATE, v_fec_nac) / 12);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN -1;   -- valor documentado: "el paciente no existe"
END fn_edad_paciente;
/

-- ---------------------------------------------------------------------
-- 2.2 PORCENTAJE DE DESCUENTO POR TERCERA EDAD
-- Busca la edad en la tabla parametrica PORC_DESCTO_3RA_EDAD
-- (65-70: 2%, 71-75: 5%, 76-80: 8%, 81-85: 10%, 86 o mas: 20%).
-- Si la edad no esta en ningun tramo (menor de 65) retorna 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_porc_descto_3ra_edad
  (p_edad IN NUMBER)
RETURN NUMBER
IS
  v_porc  porc_descto_3ra_edad.porcentaje_descto%TYPE;
BEGIN
  SELECT porcentaje_descto
    INTO v_porc
    FROM porc_descto_3ra_edad
   WHERE p_edad BETWEEN anno_ini AND anno_ter;

  RETURN v_porc;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;   -- no es adulto mayor: sin descuento
END fn_porc_descto_3ra_edad;
/

-- ---------------------------------------------------------------------
-- 2.3 MULTA DIARIA POR ATRASO SEGUN ESPECIALIDAD
-- Regla definida por el equipo (pesos por cada dia de atraso):
--   Cirugias (100, 1300, 1400, 1900)                  -> $1.200
--   Cardiologia, Neurologia, Oncologia (1500, 800, 1700) -> $1.000
--   Traumatologia, Fisiatria, Oftalmologia (200, 500, 1000) -> $900
--   Resto de especialidades                           -> $700
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_multa_diaria
  (p_esp_id IN NUMBER)
RETURN NUMBER
IS
BEGIN
  RETURN CASE
           WHEN p_esp_id IN (100, 1300, 1400, 1900) THEN 1200
           WHEN p_esp_id IN (1500, 800, 1700)       THEN 1000
           WHEN p_esp_id IN (200, 500, 1000)        THEN 900
           ELSE 700
         END;
END fn_multa_diaria;
/

-- ---------------------------------------------------------------------
-- 2.4 COPAGO DEL PACIENTE PARA UNA ATENCION
-- SALUD.costo_pago es el % del costo que paga el paciente segun su
-- convenio (Fonasa A = 0%, Particular = 100%, etc.).
-- Si el paciente es adulto mayor se aplica ademas el descuento por edad.
-- Usa: fn_edad_paciente (2.1) y fn_porc_descto_3ra_edad (2.2).
-- Si la atencion no existe retorna -1.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_copago_paciente
  (p_ate_id IN NUMBER)
RETURN NUMBER
IS
  v_costo     atencion.costo%TYPE;
  v_pac_run   atencion.pac_run%TYPE;
  v_porc_pago salud.costo_pago%TYPE;
  v_copago    NUMBER;
  v_descto    NUMBER;
BEGIN
  SELECT a.costo, a.pac_run, NVL(s.costo_pago, 100)
    INTO v_costo, v_pac_run, v_porc_pago
    FROM atencion a
    JOIN paciente p ON p.pac_run = a.pac_run
    LEFT JOIN salud s ON s.sal_id = p.sal_id
   WHERE a.ate_id = p_ate_id;

  v_copago := v_costo * v_porc_pago / 100;
  v_descto := v_copago * fn_porc_descto_3ra_edad(fn_edad_paciente(v_pac_run)) / 100;

  RETURN ROUND(v_copago - v_descto);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN -1;   -- la atencion no existe
END fn_copago_paciente;
/

-- ---------------------------------------------------------------------
-- 2.5 PORCENTAJE DE INCENTIVO DEL MEDICO
-- Regla definida por el equipo:
--   segun cantidad de atenciones del mes:
--     0 a 2 = 0%    3 a 5 = 5%    6 o mas = 8%
--   + 2% adicional si tiene 10 o mas anios de contrato.
-- Si el medico no existe retorna 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_porc_incentivo
  (p_med_run       IN NUMBER,
   p_cant_atenciones IN NUMBER)
RETURN NUMBER
IS
  v_fec_contrato  medico.fecha_contrato%TYPE;
  v_porc          NUMBER := 0;
BEGIN
  SELECT fecha_contrato
    INTO v_fec_contrato
    FROM medico
   WHERE med_run = p_med_run;

  IF p_cant_atenciones >= 6 THEN
    v_porc := 8;
  ELSIF p_cant_atenciones >= 3 THEN
    v_porc := 5;
  ELSE
    v_porc := 0;
  END IF;

  IF v_porc > 0 AND MONTHS_BETWEEN(SYSDATE, v_fec_contrato) / 12 >= 10 THEN
    v_porc := v_porc + 2;
  END IF;

  RETURN v_porc;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN 0;
END fn_porc_incentivo;
/

-- ---------------------------------------------------------------------
-- 2.6 CANTIDAD DE PAGOS ATRASADOS (funcion SIN parametros)
-- Un pago esta atrasado si se pago despues de su fecha de vencimiento,
-- o si no se ha pagado y la fecha de vencimiento ya paso.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_pagos_atrasados
RETURN NUMBER
IS
  v_cantidad NUMBER := 0;
BEGIN
  SELECT COUNT(*)
    INTO v_cantidad
    FROM pago_atencion
   WHERE NVL(fecha_pago, TRUNC(SYSDATE)) > fecha_venc_pago;
  RETURN v_cantidad;
END fn_total_pagos_atrasados;
/


-- =====================================================================
--  PRUEBAS DEL REQUERIMIENTO 2
-- =====================================================================

-- Prueba 1: edad y descuento de todos los pacientes adultos mayores
-- (funciones dentro del SELECT, del WHERE y del ORDER BY)
SELECT p.pac_run,
       p.pnombre || ' ' || p.apaterno                       AS paciente,
       fn_edad_paciente(p.pac_run)                          AS edad,
       fn_porc_descto_3ra_edad(fn_edad_paciente(p.pac_run)) AS porc_descto
  FROM paciente p
 WHERE fn_edad_paciente(p.pac_run) >= 65
 ORDER BY edad DESC;

-- Prueba 2: copago de cada atencion del anio actual, junto a su costo
SELECT a.ate_id,
       a.fecha_atencion,
       a.costo,
       s.descripcion                  AS convenio,
       s.costo_pago                   AS porc_paga_paciente,
       fn_copago_paciente(a.ate_id)   AS copago
  FROM atencion a
  JOIN paciente p ON p.pac_run = a.pac_run
  JOIN salud s    ON s.sal_id  = p.sal_id
 WHERE EXTRACT(YEAR FROM a.fecha_atencion) = EXTRACT(YEAR FROM SYSDATE)
 ORDER BY copago DESC;

-- Prueba 3: multa diaria de cada especialidad
SELECT esp_id, nombre, fn_multa_diaria(esp_id) AS multa_diaria
  FROM especialidad
 ORDER BY multa_diaria DESC, esp_id;

-- Prueba 4: incentivo de cada medico segun sus atenciones de agosto del anio actual
SELECT m.med_run,
       m.pnombre || ' ' || m.apaterno                     AS medico,
       COUNT(a.ate_id)                                    AS atenciones,
       fn_porc_incentivo(m.med_run, COUNT(a.ate_id))      AS porc_incentivo
  FROM medico m
  LEFT JOIN atencion a
         ON a.med_run = m.med_run
        AND EXTRACT(MONTH FROM a.fecha_atencion) = 8
        AND EXTRACT(YEAR  FROM a.fecha_atencion) = EXTRACT(YEAR FROM SYSDATE)
 GROUP BY m.med_run, m.pnombre, m.apaterno
 ORDER BY atenciones DESC;

-- Prueba 5: casos controlados
SELECT fn_edad_paciente(1)        AS paciente_inexistente,
       fn_copago_paciente(99999)  AS atencion_inexistente,
       fn_porc_descto_3ra_edad(40) AS descto_40_anios
  FROM dual;

-- Prueba 6: funcion SIN parametros dentro de un SELECT
SELECT fn_total_pagos_atrasados AS pagos_atrasados FROM dual;

-- Prueba 7: funciones invocadas desde otro programa PL/SQL (bloque anonimo)
DECLARE
  v_edad  NUMBER;
BEGIN
  v_edad := fn_edad_paciente(6626326);
  DBMS_OUTPUT.PUT_LINE('Edad paciente 6626326: ' || v_edad || ' anios');
  DBMS_OUTPUT.PUT_LINE('Descuento 3ra edad   : ' || fn_porc_descto_3ra_edad(v_edad) || '%');
  DBMS_OUTPUT.PUT_LINE('Multa diaria esp. 100: $' || fn_multa_diaria(100));
  DBMS_OUTPUT.PUT_LINE('Pagos atrasados      : ' || fn_total_pagos_atrasados);
END;
/
