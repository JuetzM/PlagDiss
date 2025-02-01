# Basis-Image mit Perl und notwendiger Abhängigkeiten
FROM perl:5.34

# Arbeitsverzeichnis festlegen
WORKDIR /usr/src/app

# Abhängigkeiten installieren
RUN cpanm --installdeps --notest .

# Kopiere die Applikation
COPY . .

# Exponiere Port 3000 (Standardport von Dancer2)
EXPOSE 3000

# Startbefehl: Starten der Dancer2-Applikation
CMD [ "plackup", "-E", "deployment", "-p", "3000", "app.pl" ]
