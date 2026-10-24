function manifest=buildManifest(realizationIds)
%BUILDMANIFEST Разбиение реализаций на train/validation/test 70/15/15 (ТЗ §21, §40).
%   Делятся целые внешние реализации (по realizationId mod 20: 0–13 train, 14–16 validation, 17–19 test),
%   а не отдельные окна: окна одной реализации коррелированы, их смешение дало бы утечку.
% Уникальные номера реализаций столбцом.
ids=unique(double(realizationIds(:)));
% Номера 0..3999 (4000+ — калибровка NPRACH).
if any(ids<0 | ids>=4000 | ids~=fix(ids)), error('nbiot:dataset:RunId','Expected main realization IDs 0:3999.'); end
% Twenty-ID blocks interleave independent realizations; never split windows.
% Остаток от деления на 20; по умолчанию — train.
bucket=mod(ids,20); split=repmat("train",size(ids));
% Остатки 14–16 — validation, 17–19 — test.
split(bucket>=14 & bucket<17)="validation"; split(bucket>=17)="test";
% Таблица: номер реализации → роль.
manifest=table(ids,split,'VariableNames',{'externalRealizationId','split'});
end
