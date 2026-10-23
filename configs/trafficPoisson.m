function cfg=trafficPoisson()
%   Конфигурация с пуассоновским трафиком (ТЗ §11.2).
cfg=nbiot.config.defaultConfig(); cfg.traffic.kind='poisson'; cfg=nbiot.config.validateConfig(cfg);
end
