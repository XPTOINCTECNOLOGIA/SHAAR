-- Auto-teste do pipeline de migrations do Azure (DDL inofensivo: cria e apaga).
CREATE TABLE IF NOT EXISTS public._xpto_pipeline_selftest (id int);
DROP TABLE IF EXISTS public._xpto_pipeline_selftest;
