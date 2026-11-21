&ИзменениеИКонтроль("А")
Процедура Тест_А()
	Х = 1;
	#Вставка // проверка прав
	ПроверитьПрава();
	#КонецВставки
	Записать();
КонецПроцедуры

&ИзменениеИКонтроль("Б")
Процедура Тест_Б()
	#Вставка
	Начать();
	#КонецВставки
	Начало();
	#Удаление
	Удалить1();
	#КонецУдаления
	Конец();
КонецПроцедуры

&ИзменениеИКонтроль("В")
Процедура Тест_В()
	Х = 1;
	#Вставка
	Проверить();
	#КонецВставки
	Записать();
	#Вставка
	Тест_Сообщить();
	#КонецВставки
КонецПроцедуры

&ИзменениеИКонтроль("Г")
Процедура Тест_Г()
	А();
	Б();
	#Удаление
	А();
	#КонецУдаления
	В();
КонецПроцедуры

Процедура Тест_Сообщить() Экспорт
	Сообщить("Готово");
КонецПроцедуры

Функция Тест_Сумма(А, Б)
	Возврат А + Б;
КонецФункции

&ChangeAndValidate("InsertRepeat")
Procedure Test_InsertRepeat()
#Insert
    A();
#EndInsert
    A();
EndProcedure
&ChangeAndValidate("DeleteRepeat")
Procedure Test_DeleteRepeat()
    A();
#Delete
    A();
#EndDelete
    A();
    A();
EndProcedure

# If Server Then
Procedure Тест_ServerOne() Export
    Message("scope");
EndProcedure

Procedure Тест_ServerTwo() Export
    Message("scope");
EndProcedure
#ElsIf Client Or ExternalConnection Then
Procedure Тест_ElseIfScope() Export
    Message("scope");
EndProcedure
#Else// comment
Procedure Тест_ElseScope() Export
    Message("scope");
EndProcedure
#EndIf

#If Server Then
Procedure Тест_ServerTail() Export
    Message("scope");
EndProcedure
#If Not ExternalConnection Then
Procedure Тест_NestedScope() Export
    Message("scope");
EndProcedure
#EndIf
#EndIf

#If Server Then
#Region SameScope
Procedure Тест_SameScopeMethod() Export
    Message("scope");
EndProcedure
#EndRegion
#EndIf

#If Server Then
#Region DifferentScope
Procedure Тест_OtherScopeMethod() Export
    Message("scope");
EndProcedure
#EndRegion
#EndIf
