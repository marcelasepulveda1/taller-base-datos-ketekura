-- =====================================================================
--  CENTRO MEDICO KETEKURA - EVALUACION PARCIAL 2 - TALLER DE BASE DE DATOS
--  TABLAS NUEVAS DE APOYO
--
--  Ejecutar DESPUES del script de creacion y poblado de Ketekura.
--  Para la entrega, pegar este contenido al final del "Script de Carga.SQL".
--  La primera vez los DROP daran error porque las tablas no existen: es normal.
-- =====================================================================

DROP TABLE pago_moroso              CASCADE CONSTRAINTS;
DROP TABLE resumen_atencion_medico  CASCADE CONSTRAINTS;
DROP TABLE error_proceso            CASCADE CONSTRAINTS;
DROP SEQUENCE sq_error;

CREATE SEQUENCE sq_error;

-- Resultado del proceso de morosidad (Req. 1 / Req. 3)
-- Un registro por cada atencion pagada fuera de plazo en el anio procesado.
CREATE TABLE pago_moroso
(ate_id           NUMBER(8)    NOT NULL,
 anno_proceso     NUMBER(4)    NOT NULL,
 pac_run          NUMBER(8)    NOT NULL,
 nombre_paciente  VARCHAR2(50) NOT NULL,
 edad_paciente    NUMBER(3)    NOT NULL,
 especialidad     VARCHAR2(40) NOT NULL,
 fecha_venc_pago  DATE         NOT NULL,
 fecha_pago       DATE,
 dias_morosidad   NUMBER(5)    NOT NULL,
 monto_multa      NUMBER(10)   NOT NULL,
 porc_descto      NUMBER(4)    NOT NULL,
 monto_descto     NUMBER(10)   NOT NULL,
 multa_final      NUMBER(10)   NOT NULL,
 fecha_proceso    DATE         NOT NULL,
 CONSTRAINT pk_pago_moroso PRIMARY KEY (ate_id),
 CONSTRAINT fk_pago_moroso_atencion FOREIGN KEY (ate_id) REFERENCES atencion (ate_id),
 CONSTRAINT fk_pago_moroso_paciente FOREIGN KEY (pac_run) REFERENCES paciente (pac_run));

-- Resumen mensual de atenciones por medico, con su incentivo (Req. 1 / Req. 3)
-- La PK (medico, anio, mes) impide que un periodo quede duplicado.
CREATE TABLE resumen_atencion_medico
(med_run          NUMBER(8)    NOT NULL,
 anno             NUMBER(4)    NOT NULL,
 mes              NUMBER(2)    NOT NULL,
 cant_atenciones  NUMBER(4)    NOT NULL,
 total_recaudado  NUMBER(10)   NOT NULL,
 porc_incentivo   NUMBER(5,2)  NOT NULL,
 monto_incentivo  NUMBER(10)   NOT NULL,
 fecha_proceso    DATE         NOT NULL,
 CONSTRAINT pk_resumen_atencion_medico PRIMARY KEY (med_run, anno, mes),
 CONSTRAINT fk_resumen_medico FOREIGN KEY (med_run) REFERENCES medico (med_run));

-- Registro de errores de los procesos
-- Si falla un registro, se anota aqui y el proceso sigue con los demas.
CREATE TABLE error_proceso
(id_error        NUMBER(8)     NOT NULL,
 nombre_proceso  VARCHAR2(60)  NOT NULL,
 descripcion     VARCHAR2(400) NOT NULL,
 fecha_error     DATE          NOT NULL,
 CONSTRAINT pk_error_proceso PRIMARY KEY (id_error));
